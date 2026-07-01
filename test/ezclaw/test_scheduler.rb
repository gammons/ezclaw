# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestScheduler < Minitest::Test
  # Processor double whose behavior is set per-test.
  class FakeProcessor
    def initialize(&blk) = (@blk = blk)
    def process(**) = @blk.call
  end

  def setup
    @logger = Ezclaw::Log.new(output: StringIO.new, level: :debug)
    @config = Ezclaw::Config.new(
      { "slack" => { "channels" => [{ "id" => "C0BDXPJ9E3E", "name" => "coach" }] } },
      "/tmp"
    )
    @posted = []
    fake_client = Object.new
    posted = @posted
    fake_client.define_singleton_method(:chat_postMessage) { |**kw| posted << kw }
    Ezclaw::Tools::SlackPostTool.slack_client = fake_client
  end

  def teardown
    Ezclaw::Tools::SlackPostTool.slack_client = nil
  end

  def test_posts_alert_to_home_channel_on_failure
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529: overloaded", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")

    assert_equal 1, @posted.length
    assert_equal "C0BDXPJ9E3E", @posted[0][:channel]
    assert_match(/heartbeat/, @posted[0][:text])
    assert_match(/529/, @posted[0][:text])
  end

  def test_no_alert_on_success
    processor = FakeProcessor.new { { role: "assistant", content: "ok" } }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")

    assert_empty @posted
  end

  def test_failure_without_slack_client_does_not_raise
    Ezclaw::Tools::SlackPostTool.slack_client = nil
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")  # must not raise
    assert_empty @posted
  end

  def test_failure_without_config_does_not_raise
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger)

    sched.trigger_now("heartbeat")  # config: nil -> no channel -> no post, no raise
    assert_empty @posted
  end
end
