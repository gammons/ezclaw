# frozen_string_literal: true

module Ezclaw
  module SlackFormatter
    # Convert GitHub-flavored markdown to Slack mrkdwn format
    def self.markdown_to_mrkdwn(text)
      return "" if text.nil? || text.empty?

      lines = text.lines
      result = []
      in_code_block = false

      lines.each do |line|
        # Toggle code block state (triple backticks pass through to Slack as-is)
        if line.strip.start_with?("```")
          in_code_block = !in_code_block
          result << line
          next
        end

        if in_code_block
          result << line
          next
        end

        # Headers → bold text
        line = line.sub(/^\#{1,6}\s+(.+)$/, '*\1*')

        # Bold: **text** or __text__ → *text*
        line = line.gsub(/\*\*(.+?)\*\*/, '*\1*')
        line = line.gsub(/__(.+?)__/, '*\1*')

        # Links: [text](url) → <url|text>
        line = line.gsub(/\[([^\]]+)\]\(([^)]+)\)/, '<\2|\1>')

        # Horizontal rules → divider
        line = line.sub(/^---+$/, '───────────────────────────')

        result << line
      end

      result.join
    end
  end
end
