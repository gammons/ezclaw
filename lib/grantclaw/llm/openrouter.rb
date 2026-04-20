# frozen_string_literal: true

module Grantclaw
  module LLM
    class OpenRouter < Base
      BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

      def initialize(model:, max_tokens: 4096, api_key_env: "OPENROUTER_API_KEY")
        super(model: model, max_tokens: max_tokens)
        @api_key = ENV.fetch(api_key_env)
        @conn = Faraday.new(url: BASE_URL) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end

      def chat(messages:, tools: [], model: nil)
        with_retries do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          raise APIError, "HTTP #{response.status}: #{response.body}" unless response.status == 200

          parse_response(response.body)
        end
      end

      private

      def build_request(messages, tools, model)
        body = {
          model: model || @model,
          messages: messages.map { |m| normalize_message(m) },
          max_tokens: @max_tokens
        }
        body[:tools] = tools.map { |t| openai_tool(t) } if tools.any?
        body
      end

      def normalize_message(msg)
        role = msg[:role] || msg["role"]
        content = msg[:content] || msg["content"]
        tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
        tool_calls = msg[:tool_calls] || msg["tool_calls"]

        result = { role: role, content: content }
        result[:tool_call_id] = tool_call_id if tool_call_id

        # Preserve tool_calls on assistant messages (OpenAI format)
        if role == "assistant" && tool_calls&.any?
          result[:tool_calls] = tool_calls.map { |tc|
            {
              id: tc[:id],
              type: "function",
              function: { name: tc[:name], arguments: JSON.generate(tc[:arguments]) }
            }
          }
        end

        result
      end

      def openai_tool(tool)
        {
          type: "function",
          function: {
            name: tool[:name],
            description: tool[:description],
            parameters: tool[:parameters]
          }
        }
      end

      def parse_response(body)
        msg = body.is_a?(String) ? JSON.parse(body) : body
        choice = msg["choices"]&.first&.fetch("message", {})
        usage = msg["usage"] || {}

        tool_calls = nil
        if choice["tool_calls"]&.any?
          tool_calls = choice["tool_calls"].map do |tc|
            {
              id: tc["id"],
              name: tc.dig("function", "name"),
              arguments: JSON.parse(tc.dig("function", "arguments") || "{}")
            }
          end
        end

        {
          role: "assistant",
          content: choice["content"],
          tool_calls: tool_calls,
          usage: { input: usage["prompt_tokens"], output: usage["completion_tokens"] }
        }
      end
    end
  end
end
