# frozen_string_literal: true

require_relative "../test_helper"

class TestLogger < Minitest::Test
  def setup
    @output = StringIO.new
    @logger = Ezclaw::Log.new(output: @output, level: :info)
  end

  def test_info_message_with_component
    @logger.info("cron", "Triggered: weekly_report")
    line = @output.string
    assert_match(/INFO/, line)
    assert_match(/\[cron\]/, line)
    assert_match(/Triggered: weekly_report/, line)
  end

  def test_debug_suppressed_at_info_level
    @logger.debug("llm", "verbose stuff")
    assert_empty @output.string
  end

  def test_debug_shown_at_debug_level
    logger = Ezclaw::Log.new(output: @output, level: :debug)
    logger.debug("llm", "verbose stuff")
    assert_match(/DEBUG/, @output.string)
  end

  def test_error_message
    @logger.error("slack", "Connection failed")
    assert_match(/ERROR/, @output.string)
    assert_match(/\[slack\]/, @output.string)
  end

  def test_level_from_string
    logger = Ezclaw::Log.new(output: @output, level: "warn")
    logger.info("test", "should not appear")
    assert_empty @output.string
    logger.warn("test", "should appear")
    assert_match(/WARN/, @output.string)
  end
end
