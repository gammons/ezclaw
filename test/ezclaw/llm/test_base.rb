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

class TestLLMBaseRetries < Minitest::Test
  # Test double: exposes with_retries, records sleeps, removes jitter for
  # deterministic assertions.
  class Retryable < Ezclaw::LLM::Base
    attr_reader :slept

    def initialize
      super(model: "fake", max_tokens: 1)
      @slept = []
    end

    def jitter(seconds) = seconds          # disable jitter in tests
    def sleep_for(seconds) = @slept << seconds

    def run(interactive:, &blk)
      with_retries(interactive: interactive, &blk)
    end
  end

  def transient = Ezclaw::LLM::APIError.new("HTTP 529: overloaded", status: 529)

  def test_interactive_uses_short_backoff
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: true) { raise transient }
    end
    assert_equal [0.2, 0.4], r.slept
  end

  def test_unattended_uses_aggressive_backoff
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: false) { raise transient }
    end
    assert_equal [5, 15, 30, 60], r.slept
  end

  def test_retries_then_succeeds
    r = Retryable.new
    calls = 0
    result = r.run(interactive: false) do
      calls += 1
      raise transient if calls < 3
      :ok
    end
    assert_equal :ok, result
    assert_equal [5, 15], r.slept  # two failures -> two sleeps
  end

  def test_non_transient_is_not_retried
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: false) { raise Ezclaw::LLM::APIError.new("HTTP 400: bad", status: 400) }
    end
    assert_equal [], r.slept
  end

  def test_first_try_success_does_not_sleep
    r = Retryable.new
    calls = 0
    result = r.run(interactive: false) do
      calls += 1
      :ok
    end
    assert_equal :ok, result
    assert_equal 1, calls
    assert_equal [], r.slept
  end
end

class TestLLMBaseJitter < Minitest::Test
  class Bare < Ezclaw::LLM::Base
    def initialize = super(model: "fake", max_tokens: 1)
  end

  def test_jitter_stays_within_plus_minus_20_percent_and_nonnegative
    bare = Bare.new
    base = 30
    1000.times do
      j = bare.send(:jitter, base)
      assert_operator j, :>=, base * 0.8
      assert_operator j, :<, base * 1.2
      assert_operator j, :>=, 0
    end
  end

  def test_jitter_is_a_float
    assert_kind_of Float, Bare.new.send(:jitter, 5)
  end
end
