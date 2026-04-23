# frozen_string_literal: true

module Ezclaw
  module Tools
    class SlackPostTool < Tool
      desc "Post a message to a Slack channel. Use this to share reports, alerts, or updates."
      param :channel, type: :string, desc: "Slack channel ID (e.g., C085D6W27NY)", required: true
      param :text, type: :string, desc: "Message text to post", required: true
      param :thread_ts, type: :string, desc: "Thread timestamp to reply in a thread (optional)"

      class << self
        attr_accessor :slack_client, :repl_mode
      end

      def call(channel:, text:, thread_ts: nil)
        if self.class.repl_mode
          puts "[slack_post] ##{channel}: #{text}"
          return "Message printed to console (REPL mode)."
        end

        unless self.class.slack_client
          return "Error: Slack client not configured"
        end

        formatted = SlackFormatter.markdown_to_mrkdwn(text)
        opts = { channel: channel, text: formatted }
        opts[:thread_ts] = thread_ts if thread_ts
        self.class.slack_client.chat_postMessage(**opts)
        "Message posted to #{channel}."
      end
    end
  end
end
