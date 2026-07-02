# frozen_string_literal: true

require "rufus-scheduler"

module Ezclaw
  class Scheduler
    def initialize(processor:, schedule:, logger:, config: nil)
      @processor = processor
      @schedule = schedule || {}
      @logger = logger
      @config = config
      @scheduler = Rufus::Scheduler.new
    end

    def start
      @schedule.each do |name, cron_expr|
        @logger.info("cron", "Registering schedule: #{name} = #{cron_expr}")
        @scheduler.cron(cron_expr) do
          handle_trigger(name)
        end
      end

      @logger.info("cron", "Scheduler started with #{@schedule.length} schedule(s)")
    end

    def stop
      @scheduler.shutdown(:wait)
      @logger.info("cron", "Scheduler stopped")
    end

    def trigger_now(name)
      handle_trigger(name)
    end

    private

    def handle_trigger(name)
      @logger.info("cron", "Triggered: #{name}")

      time_str = Time.now.strftime("%A %B %d, %Y %I:%M %p %Z")
      message = "Heartbeat triggered: #{name}. Current time: #{time_str}. " \
                "Check your heartbeat instructions and execute the appropriate tasks for this trigger."

      begin
        result = @processor.process(user_message: message, source: "cron:#{name}")
        @logger.info("cron", "Completed: #{name} — #{result[:content]&.slice(0, 100)}")
      rescue => e
        @logger.error("cron", "Failed: #{name} — #{e.class}: #{e.message}")
        notify_failure(name, e)
      end
    end

    # Post a Slack alert so a missed heartbeat (e.g. LLM overloaded after all
    # retries) is visible instead of dying silently in the logs. Must never
    # raise out of the rescue block above.
    def notify_failure(name, error)
      channel = alert_channel
      return unless channel

      client = Tools::SlackPostTool.slack_client
      return unless client

      text = ":warning: Heartbeat `#{name}` failed after multiple retries. " \
             "No brief was posted.\nLast error: `#{error.message.to_s.slice(0, 300)}`"
      client.chat_postMessage(channel: channel, text: text)
    rescue => e
      @logger.error("cron", "Failed to post failure alert for #{name}: #{e.class}: #{e.message}")
    end

    def alert_channel
      return nil unless @config

      channels = @config.slack["channels"] || []
      first = channels.first
      first && first["id"]
    end
  end
end
