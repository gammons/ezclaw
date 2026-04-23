# frozen_string_literal: true

require_relative "../test_helper"

class TestConfig < Minitest::Test
  def setup
    @config = Ezclaw::Config.load(File.join(FIXTURES_DIR, "bot"))
  end

  def test_loads_name
    assert_equal "test-bot", @config.name
  end

  def test_loads_llm_config
    assert_equal "openrouter", @config.llm["provider"]
    assert_equal "anthropic/claude-sonnet-4", @config.llm["model"]
    assert_equal 1024, @config.llm["max_tokens"]
  end

  def test_loads_slack_channels
    channels = @config.slack["channels"]
    assert_equal 1, channels.length
    assert_equal "C12345", channels.first["id"]
  end

  def test_loads_schedule
    assert_equal "*/10 * * * *", @config.schedule["heartbeat"]
  end

  def test_loads_system_files_content
    system_prompt = @config.system_prompt
    assert_includes system_prompt, "# Test Bot"
    assert_includes system_prompt, "You are a test bot."
  end

  def test_loads_memory_content
    assert_includes @config.memory_content, "No memories yet."
  end

  def test_bot_dir
    assert_equal File.join(FIXTURES_DIR, "bot"), @config.bot_dir
  end

  def test_log_level
    assert_equal "debug", @config.log_level
  end

  def test_log_level_defaults_to_info
    config = Ezclaw::Config.new(
      {"name" => "x", "llm" => {}, "context" => {"system_files" => [], "memory_file" => "memory.md"}},
      FIXTURES_DIR
    )
    assert_equal "info", config.log_level
  end
end
