# frozen_string_literal: true

require "reline"

module Ezclaw
  class REPL
    attr_reader :thread_ts

    def initialize(processor:, bot_name:, model:, logger:)
      @processor = processor
      @bot_name = bot_name
      @model = model
      @logger = logger
      @history = []
      # One REPL session acts like one Slack thread with no channel, so
      # per-thread tool state (e.g. report drafts) works here too.
      @thread_ts = "repl-#{Time.now.to_i}"
    end

    def run
      puts "Ezclaw v#{VERSION} | Bot: #{@bot_name} | LLM: #{@model}"
      puts "Type 'exit' or 'quit' to stop. Ctrl+C also works."
      puts

      loop do
        input = Reline.readline("> ", true)
        break if input.nil? || %w[exit quit].include?(input.strip.downcase)
        next if input.strip.empty?

        begin
          content = process_input(input)
          puts
          puts content
          puts
        rescue => e
          @logger.error("repl", "#{e.class}: #{e.message}")
          puts "Error: #{e.message}"
        end
      end

      puts "Goodbye."
    end

    # Handles one line of input and returns the reply text.
    def process_input(input)
      result = SlackContext.with(channel: nil, thread_ts: @thread_ts, message_ts: nil, user: "repl", is_dm: false) do
        @processor.process(user_message: input, conversation_history: @history, source: "repl")
      end
      @history << { role: "user", content: input }
      @history << { role: "assistant", content: result[:content] }
      result[:content]
    end
  end
end
