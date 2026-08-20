# frozen_string_literal: true

module Ezclaw
  module LLM
    class Anthropic < Base
      BASE_URL = "https://api.anthropic.com/v1/messages"

      def initialize(model:, max_tokens: 4096, api_key_env: "ANTHROPIC_API_KEY", timeout_seconds: 120, effort: nil)
        super(model: model, max_tokens: max_tokens)
        @effort = effort
        @api_key = ENV.fetch(api_key_env)
        @conn = Faraday.new(url: BASE_URL) do |f|
          f.request :json
          f.response :json
          f.options.timeout = timeout_seconds
          f.options.open_timeout = 15
          f.adapter Faraday.default_adapter
        end
      end

      def chat(messages:, tools: [], model: nil, interactive: true)
        with_retries(interactive: interactive) do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["x-api-key"] = @api_key
            req.headers["anthropic-version"] = "2023-06-01"
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
        system_text, converted = convert_messages(messages)

        body = {
          model: model || @model,
          messages: converted,
          max_tokens: @max_tokens
        }
        body[:system] = system_text if system_text
        body[:tools] = tools.map { |t| anthropic_tool(t) } if tools.any?
        # output_config.effort ("low".."max") tunes response depth/verbosity.
        # Omit the whole object when unset so older models are unaffected.
        body[:output_config] = { effort: @effort } if @effort

        body
      end

      def convert_messages(messages)
        system_text = nil
        converted = []

        messages.each do |msg|
          role = msg[:role] || msg["role"]
          content = msg[:content] || msg["content"]

          case role
          when "system"
            system_text = content
          when "assistant"
            tool_calls = msg[:tool_calls] || msg["tool_calls"]
            if tool_calls&.any?
              converted << {
                role: "assistant",
                content: tool_calls.map { |tc|
                  { type: "tool_use", id: tc[:id], name: tc[:name], input: tc[:arguments] }
                }
              }
            else
              converted << { role: "assistant", content: content }
            end
          when "tool"
            tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
            converted << {
              role: "user",
              content: [{ type: "tool_result", tool_use_id: tool_call_id, content: content }]
            }
          else
            converted << { role: role, content: anthropic_content(content) }
          end
        end

        [system_text, converted]
      end

      # Translates normalized content into Anthropic's format. A plain String
      # passes through unchanged; an array of normalized blocks (text/image)
      # is mapped to Anthropic content blocks, turning our internal image
      # representation into the { type: "image", source: { ... } } shape the
      # Messages API expects.
      def anthropic_content(content)
        return content unless content.is_a?(Array)

        content.map do |block|
          type = block[:type] || block["type"]
          case type
          when "image"
            {
              type: "image",
              source: {
                type: "base64",
                media_type: block[:media_type] || block["media_type"],
                data: block[:data] || block["data"]
              }
            }
          when "text"
            { type: "text", text: block[:text] || block["text"] }
          else
            block
          end
        end
      end

      def anthropic_tool(tool)
        {
          name: tool[:name],
          description: tool[:description],
          input_schema: tool[:parameters]
        }
      end

      def parse_response(body)
        data = body.is_a?(String) ? JSON.parse(body) : body
        usage = data["usage"] || {}

        content_text = nil
        tool_calls = nil

        (data["content"] || []).each do |block|
          case block["type"]
          when "text"
            content_text = block["text"]
          when "tool_use"
            tool_calls ||= []
            tool_calls << {
              id: block["id"],
              name: block["name"],
              arguments: block["input"]
            }
          end
        end

        {
          role: "assistant",
          content: content_text,
          tool_calls: tool_calls,
          usage: { input: usage["input_tokens"], output: usage["output_tokens"] }
        }
      end
    end
  end
end
