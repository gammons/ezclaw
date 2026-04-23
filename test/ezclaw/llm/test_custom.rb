# frozen_string_literal: true

require_relative "../../test_helper"

class TestCustom < Minitest::Test
  def setup
    ENV["ZAI_API_KEY"] = "zai-key"
  end

  def teardown
    ENV.delete("ZAI_API_KEY")
  end

  def test_custom_openai_format
    adapter = Ezclaw::LLM::Custom.new(
      model: "glm-5-turbo",
      base_url: "https://api.z.ai/api/v1/chat/completions",
      format: "openai",
      api_key_env: "ZAI_API_KEY"
    )

    stub_request(:post, "https://api.z.ai/api/v1/chat/completions")
      .to_return(
        status: 200,
        body: JSON.generate({
          choices: [{ message: { role: "assistant", content: "Hello from Z.AI" } }],
          usage: { prompt_tokens: 5, completion_tokens: 3 }
        }),
        headers: { "Content-Type" => "application/json" }
      )

    result = adapter.chat(messages: [{ role: "user", content: "Hi" }])
    assert_equal "Hello from Z.AI", result[:content]
  end

  def test_custom_anthropic_format
    adapter = Ezclaw::LLM::Custom.new(
      model: "custom-claude",
      base_url: "https://custom.api/v1/messages",
      format: "anthropic",
      api_key_env: "ZAI_API_KEY"
    )

    stub_request(:post, "https://custom.api/v1/messages")
      .to_return(
        status: 200,
        body: JSON.generate({
          content: [{ type: "text", text: "Custom response" }],
          usage: { input_tokens: 5, output_tokens: 3 }
        }),
        headers: { "Content-Type" => "application/json" }
      )

    result = adapter.chat(messages: [{ role: "user", content: "Hi" }])
    assert_equal "Custom response", result[:content]
  end
end
