# frozen_string_literal: true

require_relative "../../test_helper"

class TestOpenRouter < Minitest::Test
  def setup
    ENV["OPENROUTER_API_KEY"] = "test-key"
    @adapter = Ezclaw::LLM::OpenRouter.new(model: "anthropic/claude-sonnet-4", max_tokens: 1024)
  end

  def teardown
    ENV.delete("OPENROUTER_API_KEY")
    super # webmock/minitest resets request counts in Minitest::Test#teardown
  end

  def test_chat_text_response
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .with(
        headers: { "Authorization" => "Bearer test-key", "Content-Type" => "application/json" }
      )
      .to_return(
        status: 200,
        body: JSON.generate({
          choices: [{ message: { role: "assistant", content: "Hello!" } }],
          usage: { prompt_tokens: 10, completion_tokens: 5 }
        }),
        headers: { "Content-Type" => "application/json" }
      )

    result = @adapter.chat(messages: [{ role: "user", content: "Hi" }])
    assert_equal "assistant", result[:role]
    assert_equal "Hello!", result[:content]
    assert_nil result[:tool_calls]
  end

  def test_chat_with_tool_calls
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(
        status: 200,
        body: JSON.generate({
          choices: [{ message: {
            role: "assistant",
            content: nil,
            tool_calls: [{
              id: "call_123",
              type: "function",
              function: { name: "greet", arguments: '{"name":"Grant"}' }
            }]
          } }],
          usage: { prompt_tokens: 10, completion_tokens: 20 }
        }),
        headers: { "Content-Type" => "application/json" }
      )

    result = @adapter.chat(
      messages: [{ role: "user", content: "Greet Grant" }],
      tools: [{ name: "greet", description: "Greet", parameters: { type: "object", properties: { "name" => { type: "string" } }, required: ["name"] } }]
    )

    assert_equal 1, result[:tool_calls].length
    assert_equal "greet", result[:tool_calls][0][:name]
    assert_equal({ "name" => "Grant" }, result[:tool_calls][0][:arguments])
  end

  def test_sends_tools_in_openai_format
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(
        status: 200,
        body: JSON.generate({ choices: [{ message: { role: "assistant", content: "ok" } }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    @adapter.chat(
      messages: [{ role: "user", content: "test" }],
      tools: [{ name: "foo", description: "bar", parameters: { type: "object", properties: {} } }]
    )

    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions") { |req|
      body = JSON.parse(req.body)
      body["tools"]&.first&.dig("function", "name") == "foo"
    }
  end

  def test_converts_image_content_blocks_to_openai_vision_format
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(
        status: 200,
        body: JSON.generate({ choices: [{ message: { role: "assistant", content: "ok" } }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    @adapter.chat(messages: [
      { role: "user", content: [
        { type: "text", text: "what is this?" },
        { type: "image", media_type: "image/png", data: "QUJD" }
      ] }
    ])

    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions") { |req|
      body = JSON.parse(req.body)
      user = body["messages"].find { |m| m["role"] == "user" }
      content = user && user["content"]
      next false unless content.is_a?(Array)

      text_block = content.find { |c| c["type"] == "text" }
      image_block = content.find { |c| c["type"] == "image_url" }

      text_block && text_block["text"] == "what is this?" &&
        image_block &&
        image_block["image_url"] &&
        image_block["image_url"]["url"] == "data:image/png;base64,QUJD"
    }
  end

  def test_retries_on_server_error
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")
      .then
      .to_return(
        status: 200,
        body: JSON.generate({ choices: [{ message: { role: "assistant", content: "ok" } }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    result = @adapter.chat(messages: [{ role: "user", content: "test" }])
    assert_equal "ok", result[:content]
  end

  def test_raises_after_max_retries
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 500, body: "fail").times(3)

    assert_raises(Ezclaw::LLM::APIError) do
      @adapter.chat(messages: [{ role: "user", content: "test" }])
    end
  end

  def test_does_not_retry_client_error
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 400, body: "bad request")

    assert_raises(Ezclaw::LLM::APIError) do
      @adapter.chat(messages: [{ role: "user", content: "test" }])
    end
    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions", times: 1)
  end

  def test_unattended_context_retries_aggressively
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 529, body: "overloaded").times(5)

    # Stub the sleep seam so the test doesn't actually wait ~110s.
    slept = []
    @adapter.define_singleton_method(:sleep_for) { |s| slept << s }

    assert_raises(Ezclaw::LLM::APIError) do
      @adapter.chat(messages: [{ role: "user", content: "test" }], interactive: false)
    end
    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions", times: 5)
    assert_equal 4, slept.length
  end
end
