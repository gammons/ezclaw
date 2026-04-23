# frozen_string_literal: true

require "rufus-scheduler"

module Ezclaw
  class Scheduler
    def initialize(processor:, schedule:, logger:)
      @processor = processor
      @schedule = schedule || {}
      @logger = logger
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
      end
    end
  end
end
