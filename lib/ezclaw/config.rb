# frozen_string_literal: true

require "yaml"

module Ezclaw
  class Config
    attr_reader :bot_dir

    def self.load(bot_dir)
      yaml = YAML.safe_load_file(File.join(bot_dir, "config.yaml"))
      new(yaml, bot_dir)
    end

    def initialize(yaml, bot_dir)
      @yaml = yaml
      @bot_dir = bot_dir
    end

    def name
      @yaml["name"]
    end

    def llm
      @yaml.fetch("llm", {})
    end

    def slack
      @yaml.fetch("slack", {})
    end

    def schedule
      @yaml.fetch("schedule", {})
    end

    def context
      @yaml.fetch("context", {})
    end

    def log_level
      @yaml.dig("logging", "level") || "info"
    end

    def max_tool_iterations
      @yaml["max_tool_iterations"]
    end

    def system_prompt
      files = context.fetch("system_files", [])
      files.map { |f| read_bot_file(f) }.join("\n---\n")
    end

    def memory_content
      file = context["memory_file"]
      return "" unless file

      read_bot_file(file)
    end

    private

    def read_bot_file(filename)
      path = File.join(@bot_dir, filename)
      return "" unless File.exist?(path)

      File.read(path)
    end
  end
end
