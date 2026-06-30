# frozen_string_literal: true

require_relative "../../test_helper"

class TestLLMBaseAPIError < Minitest::Test
  def test_5xx_and_429_are_transient
    assert Ezclaw::LLM::APIError.new("x", status: 500).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 503).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 529).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 429).transient?
  end

  def test_4xx_other_than_429_is_not_transient
    refute Ezclaw::LLM::APIError.new("x", status: 400).transient?
    refute Ezclaw::LLM::APIError.new("x", status: 401).transient?
    refute Ezclaw::LLM::APIError.new("x", status: 404).transient?
  end

  def test_nil_status_is_not_transient
    refute Ezclaw::LLM::APIError.new("x").transient?
  end

  def test_message_is_preserved
    assert_equal "boom", Ezclaw::LLM::APIError.new("boom", status: 500).message
  end
end
