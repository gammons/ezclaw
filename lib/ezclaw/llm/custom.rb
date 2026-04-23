# frozen_string_literal: true

module Ezclaw
  module LLM
    class Custom < Base
      def initialize(model:, base_url:, format: "openai", max_tokens: 4096, api_key_env: nil)
        super(model: model, max_tokens: max_tokens)
        @base_url = base_url
        @format = format
        @api_key = api_key_env ? ENV.fetch(api_key_env) : nil

        @delegate = if @format == "anthropic"
          AnthropicDelegate.new(model: model, max_tokens: max_tokens, base_url: base_url, api_key: @api_key)
        else
          OpenAIDelegate.new(model: model, max_tokens: max_tokens, base_url: base_url, api_key: @api_key)
        end
      end

      def chat(messages:, tools: [], model: nil)
        @delegate.chat(messages: messages, tools: tools, model: model)
      end

      class OpenAIDelegate < OpenRouter
        def initialize(model:, max_tokens:, base_url:, api_key:)
          @model = model
          @max_tokens = max_tokens
          @api_key = api_key || ""
          @conn = Faraday.new(url: base_url) do |f|
            f.request :json
            f.response :json
            f.options.timeout = 120
            f.options.open_timeout = 15
            f.adapter Faraday.default_adapter
          end
        end
      end

      class AnthropicDelegate < Anthropic
        def initialize(model:, max_tokens:, base_url:, api_key:)
          @model = model
          @max_tokens = max_tokens
          @api_key = api_key || ""
          @conn = Faraday.new(url: base_url) do |f|
            f.request :json
            f.response :json
            f.options.timeout = 120
            f.options.open_timeout = 15
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
