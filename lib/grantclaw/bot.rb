# frozen_string_literal: true

require "fileutils"

module Grantclaw
  class Bot
    attr_reader :config, :processor, :logger

    def initialize(bot_dir:, data_dir: nil)
      @config = Config.load(bot_dir)
      @data_dir = data_dir || ENV.fetch("GRANTCLAW_DATA_DIR", File.join(bot_dir, "data"))

      FileUtils.mkdir_p(@data_dir)

      @logger = Log.new(level: @config.log_level)
      @logger.info("bot", "Loading bot: #{@config.name}")

      @llm = build_llm
      @memory = Memory.new(
        config_dir: bot_dir,
        data_dir: @data_dir,
        filename: @config.context.fetch("memory_file", "memory.md")
      )
      @registry = build_tool_registry(bot_dir)
      @processor = MessageProcessor.new(
        llm: @llm,
        memory: @memory,
        tool_registry: @registry,
        system_prompt: @config.system_prompt,
        logger: @logger,
        max_tool_iterations: @config.max_tool_iterations
      )

      @logger.info("bot", "Bot loaded: #{@config.name} | LLM: #{@config.llm['provider']}/#{@config.llm['model']}")
    end

    def run(mode: :production)
      case mode
      when :repl
        run_repl
      when :dry
        run_dry
      when :production
        run_production
      end
    end

    private

    def build_llm
      llm_config = @config.llm
      provider = llm_config["provider"]

      case provider
      when "openrouter"
        LLM::OpenRouter.new(
          model: llm_config["model"],
          max_tokens: llm_config.fetch("max_tokens", 4096),
          api_key_env: llm_config.fetch("api_key_env", "OPENROUTER_API_KEY")
        )
      when "anthropic"
        LLM::Anthropic.new(
          model: llm_config["model"],
          max_tokens: llm_config.fetch("max_tokens", 4096),
          api_key_env: llm_config.fetch("api_key_env", "ANTHROPIC_API_KEY")
        )
      when "custom"
        LLM::Custom.new(
          model: llm_config["model"],
          base_url: llm_config.fetch("base_url"),
          format: llm_config.fetch("format", "openai"),
          max_tokens: llm_config.fetch("max_tokens", 4096),
          api_key_env: llm_config["api_key_env"]
        )
      else
        raise "Unknown LLM provider: #{provider}"
      end
    end

    def build_tool_registry(bot_dir)
      registry = ToolRegistry.new

      Tools::UpdateMemoryTool.memory = @memory
      registry.register("update_memory", Tools::UpdateMemoryTool)
      registry.register("slack_post", Tools::SlackPostTool)
      registry.register("web_fetch", Tools::WebFetchTool)
      registry.register("shell_exec", Tools::ShellExecTool)

      tools_dir = File.join(bot_dir, "tools")
      registry.load_directory(tools_dir)

      @logger.info("bot", "Loaded #{registry.schemas.length} tool(s)")
      registry
    end

    def run_repl
      @logger.info("bot", "Starting in REPL mode")
      Tools::SlackPostTool.repl_mode = true

      repl = REPL.new(
        processor: @processor,
        bot_name: @config.name,
        model: "#{@config.llm['provider']}/#{@config.llm['model']}",
        logger: @logger
      )
      repl.run
    end

    def run_dry
      @logger.info("bot", "Starting dry run")
      scheduler = Scheduler.new(processor: @processor, schedule: @config.schedule, logger: @logger)

      @config.schedule.each_key do |name|
        @logger.info("bot", "Dry run trigger: #{name}")
        scheduler.trigger_now(name)
      end

      @logger.info("bot", "Dry run complete")
    end

    def run_production
      @logger.info("bot", "Starting in production mode")

      slack = nil
      if ENV["SLACK_BOT_TOKEN"] && ENV["SLACK_APP_TOKEN"]
        slack = SlackListener.new(processor: @processor, config: @config, logger: @logger)
        Tools::SlackPostTool.slack_client = slack.web_client
        Tools::SlackPostTool.repl_mode = false
        slack.start
      else
        @logger.warn("bot", "SLACK_BOT_TOKEN/SLACK_APP_TOKEN not set, Slack disabled")
        Tools::SlackPostTool.repl_mode = true
      end

      scheduler = Scheduler.new(processor: @processor, schedule: @config.schedule, logger: @logger)
      scheduler.start

      @logger.info("bot", "Bot running. Press Ctrl+C to stop.")
      trap("INT") do
        @logger.info("bot", "Shutting down...")
        scheduler.stop
        slack&.stop
        exit(0)
      end
      trap("TERM") do
        @logger.info("bot", "Shutting down...")
        scheduler.stop
        slack&.stop
        exit(0)
      end

      sleep
    end
  end
end
