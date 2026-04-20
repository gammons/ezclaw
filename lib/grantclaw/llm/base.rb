# frozen_string_literal: true

require "faraday"
require "json"

module Grantclaw
  module LLM
    class APIError < StandardError; end

    class Base
      MAX_RETRIES = 3

      def initialize(model:, max_tokens: 4096)
        @model = model
        @max_tokens = max_tokens
      end

      def chat(messages:, tools: [], model: nil)
        raise NotImplementedError
      end

      private

      def with_retries
        attempts = 0
        begin
          attempts += 1
          yield
        rescue APIError => e
          raise if attempts >= MAX_RETRIES
          sleep(0.1 * (2**attempts))
          retry
        end
      end
    end
  end
end
