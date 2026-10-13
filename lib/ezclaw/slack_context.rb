# frozen_string_literal: true

module Ezclaw
  # Details of the Slack message currently being processed, so tools can
  # tell which channel/thread/user triggered them without the LLM copying
  # IDs into tool arguments. Set by SlackListener around
  # MessageProcessor#process (tool calls run synchronously on that same
  # Ruby thread). nil during cron/heartbeat runs and in the REPL.
  module SlackContext
    KEY = :ezclaw_slack_context

    def self.current
      Thread.current[KEY]
    end

    def self.with(channel:, thread_ts:, message_ts:, user:, is_dm:)
      previous = Thread.current[KEY]
      Thread.current[KEY] = {
        channel: channel, thread_ts: thread_ts, message_ts: message_ts,
        user: user, is_dm: is_dm
      }.freeze
      yield
    ensure
      Thread.current[KEY] = previous
    end
  end
end
