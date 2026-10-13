# frozen_string_literal: true

require_relative "../test_helper"

class TestSlackContext < Minitest::Test
  CTX = { channel: "C1", thread_ts: "1.0", message_ts: "1.1", user: "U1", is_dm: false }.freeze

  def test_current_is_nil_outside_with
    assert_nil Ezclaw::SlackContext.current
  end

  def test_with_exposes_context_inside_block_and_clears_after
    seen = Ezclaw::SlackContext.with(**CTX) { Ezclaw::SlackContext.current }
    assert_equal CTX, seen
    assert_nil Ezclaw::SlackContext.current
  end

  def test_with_returns_block_value
    assert_equal 42, Ezclaw::SlackContext.with(**CTX) { 42 }
  end

  def test_with_restores_previous_context_when_nested_and_on_error
    Ezclaw::SlackContext.with(**CTX) do
      assert_raises(RuntimeError) do
        Ezclaw::SlackContext.with(**CTX, channel: "C2") { raise "boom" }
      end
      assert_equal "C1", Ezclaw::SlackContext.current[:channel]
    end
    assert_nil Ezclaw::SlackContext.current
  end

  def test_context_is_per_thread
    Ezclaw::SlackContext.with(**CTX) do
      assert_nil Thread.new { Ezclaw::SlackContext.current }.value
    end
  end
end
