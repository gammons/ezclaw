# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestRepl < Minitest::Test
  def build_repl(processor)
    Ezclaw::REPL.new(processor: processor, bot_name: "t", model: "m",
                     logger: Ezclaw::Log.new(output: StringIO.new, level: :debug))
  end

  def test_tools_see_a_session_thread_with_no_channel
    seen = []
    processor = Object.new
    processor.define_singleton_method(:process) do |**|
      seen << Ezclaw::SlackContext.current
      { content: "ok" }
    end
    repl = build_repl(processor)

    assert_equal "ok", repl.process_input("one")
    repl.process_input("two")

    assert_equal 2, seen.length
    assert_nil seen[0][:channel]
    assert_nil seen[0][:message_ts]
    assert_equal "repl", seen[0][:user]
    assert_match(/\Arepl-\d+\z/, seen[0][:thread_ts])
    assert_equal seen[0][:thread_ts], seen[1][:thread_ts]
    assert_equal repl.thread_ts, seen[0][:thread_ts]
    assert_nil Ezclaw::SlackContext.current, "context must not leak outside process_input"
  end

  def test_keeps_conversation_history
    histories = []
    processor = Object.new
    processor.define_singleton_method(:process) do |conversation_history:, **|
      histories << conversation_history.dup
      { content: "reply" }
    end
    repl = build_repl(processor)

    repl.process_input("one")
    repl.process_input("two")

    assert_equal [], histories[0]
    assert_equal [{ role: "user", content: "one" }, { role: "assistant", content: "reply" }], histories[1]
  end
end
