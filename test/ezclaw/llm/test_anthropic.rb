# frozen_string_literal: true

require_relative "../../test_helper"

class TestAnthropic < Minitest::Test
  def setup
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    @adapter = Ezclaw::LLM::Anthropic.new(model: "claude-sonnet-4-20250514", max_tokens: 1024)
  end

  def teardown
    ENV.delete("ANTHROPIC_API_KEY")
    super
  end

  def test_chat_text_response
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({
          content: [{ type: "text", text: "Hello!" }],
          usage: { input_tokens: 10, output_tokens: 5 }
        }),
        headers: { "Content-Type" => "application/json" }
      )

    result = @adapter.chat(messages: [
      { role: "system", content: "You are helpful." },
      { role: "user", content: "Hi" }
    ])
    assert_equal "assistant", result[:role]
    assert_equal "Hello!", result[:content]
  end

  def test_extracts_system_from_messages
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({ content: [{ type: "text", text: "ok" }], usage: { input_tokens: 1, output_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    @adapter.chat(messages: [
      { role: "system", content: "Be concise." },
      { role: "user", content: "Hi" }
    ])

    assert_requested(:post, "https://api.anthropic.com/v1/messages") { |req|
      body = JSON.parse(req.body)
      body["system"] == "Be concise." &&
        body["messages"].none? { |m| m["role"] == "system" }
    }
  end

  def test_chat_with_tool_calls
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({
          content: [
            { type: "tool_use", id: "tu_123", name: "greet", input: { "name" => "Grant" } }
          ],
          usage: { input_tokens: 10, output_tokens: 20 }
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

  def test_converts_image_content_blocks
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({ content: [{ type: "text", text: "I see a chart." }], usage: { input_tokens: 1, output_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    @adapter.chat(messages: [
      { role: "user", content: [
        { type: "text", text: "what is this?" },
        { type: "image", media_type: "image/png", data: "QUJD" }
      ] }
    ])

    assert_requested(:post, "https://api.anthropic.com/v1/messages") { |req|
      body = JSON.parse(req.body)
      user = body["messages"].find { |m| m["role"] == "user" }
      content = user && user["content"]
      next false unless content.is_a?(Array)

      text_block = content.find { |c| c["type"] == "text" }
      image_block = content.find { |c| c["type"] == "image" }

      text_block && text_block["text"] == "what is this?" &&
        image_block &&
        image_block["source"] &&
        image_block["source"]["type"] == "base64" &&
        image_block["source"]["media_type"] == "image/png" &&
        image_block["source"]["data"] == "QUJD"
    }
  end

  def test_tool_result_message_format
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({ content: [{ type: "text", text: "Got it." }], usage: { input_tokens: 1, output_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )

    @adapter.chat(messages: [
      { role: "user", content: "do it" },
      { role: "assistant", content: nil, tool_calls: [{ id: "tu_1", name: "greet", arguments: { "name" => "X" } }] },
      { role: "tool", tool_call_id: "tu_1", content: "Hello X!" }
    ])

    assert_requested(:post, "https://api.anthropic.com/v1/messages") { |req|
      body = JSON.parse(req.body)
      msgs = body["messages"]
      msgs.any? { |m| m["role"] == "user" && m["content"].is_a?(Array) && m["content"].any? { |c| c["type"] == "tool_result" } }
    }
  end
  def test_default_timeout_is_120
    assert_equal 120, @adapter.instance_variable_get(:@conn).options.timeout
  end

  def test_timeout_seconds_is_configurable
    adapter = Ezclaw::LLM::Anthropic.new(model: "claude-sonnet-4-20250514", max_tokens: 1024, timeout_seconds: 600)
    assert_equal 600, adapter.instance_variable_get(:@conn).options.timeout
  end

  def stub_simple_ok
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({ content: [{ type: "text", text: "ok" }], usage: { input_tokens: 1, output_tokens: 1 } }),
        headers: { "Content-Type" => "application/json" }
      )
  end

  def test_effort_omitted_by_default
    stub_simple_ok
    @adapter.chat(messages: [{ role: "user", content: "Hi" }])
    assert_requested(:post, "https://api.anthropic.com/v1/messages") { |req|
      !JSON.parse(req.body).key?("output_config")
    }
  end

  def test_effort_sent_as_output_config
    stub_simple_ok
    adapter = Ezclaw::LLM::Anthropic.new(model: "claude-opus-5", max_tokens: 1024, effort: "medium")
    adapter.chat(messages: [{ role: "user", content: "Hi" }])
    assert_requested(:post, "https://api.anthropic.com/v1/messages") { |req|
      JSON.parse(req.body)["output_config"] == { "effort" => "medium" }
    }
  end

end
