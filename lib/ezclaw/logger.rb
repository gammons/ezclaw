# frozen_string_literal: true

module Ezclaw
  class Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    def initialize(output: $stdout, level: :info)
      @output = output
      @level = resolve_level(level)
      @mutex = Mutex.new
    end

    def debug(component, message) = log(:debug, component, message)
    def info(component, message)  = log(:info, component, message)
    def warn(component, message)  = log(:warn, component, message)
    def error(component, message) = log(:error, component, message)

    private

    def log(level, component, message)
      return if LEVELS[level] < @level

      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      label = level.to_s.upcase.ljust(5)
      line = "[#{timestamp}] #{label} [#{component}] #{message}\n"

      @mutex.synchronize { @output.write(line) }
    end

    def resolve_level(level)
      level = level.to_sym if level.is_a?(String)
      LEVELS.fetch(level) { raise ArgumentError, "Unknown log level: #{level}" }
    end
  end
end
