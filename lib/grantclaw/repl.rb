# frozen_string_literal: true

require "reline"

module Grantclaw
  class REPL
    def initialize(processor:, bot_name:, model:, logger:)
      @processor = processor
      @bot_name = bot_name
      @model = model
      @logger = logger
      @history = []
    end

    def run
      puts "Grantclaw v#{VERSION} | Bot: #{@bot_name} | LLM: #{@model}"
      puts "Type 'exit' or 'quit' to stop. Ctrl+C also works."
      puts

      loop do
        input = Reline.readline("> ", true)
        break if input.nil? || %w[exit quit].include?(input.strip.downcase)
        next if input.strip.empty?

        begin
          result = @processor.process(
            user_message: input,
            conversation_history: @history,
            source: "repl"
          )

          puts
          puts result[:content]
          puts

          @history << { role: "user", content: input }
          @history << { role: "assistant", content: result[:content] }
        rescue => e
          @logger.error("repl", "#{e.class}: #{e.message}")
          puts "Error: #{e.message}"
        end
      end

      puts "Goodbye."
    end
  end
end
