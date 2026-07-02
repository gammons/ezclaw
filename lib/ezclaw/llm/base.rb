# frozen_string_literal: true

require "faraday"
require "json"

module Ezclaw
  module LLM
    class APIError < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end

      # Transient = worth retrying. Upstream rate-limits (429) and server
      # errors (5xx) clear on their own; other 4xx are caller bugs and must
      # fail fast.
      def transient?
        status == 429 || (status.is_a?(Integer) && status >= 500 && status < 600)
      end
    end

    class Base
      # Interactive: a human is waiting — fail fast (2 retries, sub-second).
      INTERACTIVE_BACKOFF = [0.2, 0.4].freeze
      # Unattended (cron/heartbeat): nobody is waiting — ride out transient
      # upstream overloads (4 retries, ~110s cumulative).
      UNATTENDED_BACKOFF = [5, 15, 30, 60].freeze
      JITTER_RATIO = 0.2

      def initialize(model:, max_tokens: 4096)
        @model = model
        @max_tokens = max_tokens
      end

      def chat(messages:, tools: [], model: nil, interactive: true)
        raise NotImplementedError
      end

      private

      def with_retries(interactive: true)
        schedule = interactive ? INTERACTIVE_BACKOFF : UNATTENDED_BACKOFF
        attempt = 0
        begin
          yield
        rescue APIError => e
          raise unless e.transient?
          raise if attempt >= schedule.length
          sleep_for(jitter(schedule[attempt]))
          attempt += 1
          retry
        end
      end

      # +/- JITTER_RATIO randomization so multiple bots don't retry in lockstep.
      def jitter(seconds)
        delta = seconds * JITTER_RATIO
        seconds + rand(-delta..delta)
      end

      # Seam so tests can capture backoff without real sleeping.
      def sleep_for(seconds)
        sleep(seconds)
      end
    end
  end
end
