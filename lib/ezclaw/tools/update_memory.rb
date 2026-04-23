# frozen_string_literal: true

module Ezclaw
  module Tools
    class UpdateMemoryTool < Tool
      desc "Update the bot's long-term memory file. Use this to remember important facts, decisions, or state changes across sessions."
      param :content, type: :string, desc: "The full new content for memory.md. This replaces the entire file.", required: true

      class << self
        attr_accessor :memory
      end

      def call(content:)
        unless self.class.memory
          return "Error: memory not configured"
        end

        self.class.memory.update(content)
        "Memory updated successfully."
      end
    end
  end
end
