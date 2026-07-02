# frozen_string_literal: true

module Ezclaw
  module LLM
    class OpenRouter < Base
      BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

      def initialize(model:, max_tokens: 4096, api_key_env: "OPENROUTER_API_KEY")
        super(model: model, max_tokens: max_tokens)
        @api_key = ENV.fetch(api_key_env)
        @conn = Faraday.new(url: BASE_URL) do |f|
          f.request :json
          f.response :json
          f.options.timeout = 120
          f.options.open_timeout = 15
          f.adapter Faraday.default_adapter
        end
      end

      def chat(messages:, tools: [], model: nil, interactive: true)
        with_retries(interactive: interactive) do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          unless response.status == 200
            raise APIError.new("HTTP #{response.status}: #{response.body}", status: response.status)
          end

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

        result = { role: role, content: openai_content(content) }
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

      # Translates normalized content into OpenAI's chat format. A plain String
      # passes through unchanged; an array of normalized blocks (text/image) is
      # mapped to OpenAI multimodal parts, encoding our internal image
      # representation as a base64 data URI under image_url.
      def openai_content(content)
        return content unless content.is_a?(Array)

        content.map do |block|
          type = block[:type] || block["type"]
          case type
          when "image"
            media_type = block[:media_type] || block["media_type"]
            data = block[:data] || block["data"]
            {
              type: "image_url",
              image_url: { url: "data:#{media_type};base64,#{data}" }
            }
          when "text"
            { type: "text", text: block[:text] || block["text"] }
          else
            block
          end
        end
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
