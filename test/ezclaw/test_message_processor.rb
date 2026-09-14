# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class FakeLLM < Ezclaw::LLM::Base
  attr_accessor :responses
  attr_reader :last_messages, :last_tools

  def initialize
    super(model: "fake", max_tokens: 100)
    @responses = []
    @call_count = 0
    @last_messages = nil
    @last_tools = nil
  end

  attr_reader :last_interactive

  def chat(messages:, tools: [], model: nil, interactive: true)
    @last_interactive = interactive
    @last_messages = messages
    @last_tools = tools
    resp = @responses[@call_count] || { role: "assistant", content: "default response", tool_calls: nil }
    @call_count += 1
    resp
  end
end

class TestMessageProcessor < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_dir = File.join(@tmpdir, "config")
    @data_dir = File.join(@tmpdir, "data")
    Dir.mkdir(@config_dir)
    Dir.mkdir(@data_dir)

    File.write(File.join(@config_dir, "role.md"), "You are a test bot.")
    File.write(File.join(@config_dir, "memory.md"), "No memories.")

    @llm = FakeLLM.new
    @memory = Ezclaw::Memory.new(config_dir: @config_dir, data_dir: @data_dir, filename: "memory.md")
    @registry = Ezclaw::ToolRegistry.new
    @logger = Ezclaw::Log.new(output: StringIO.new, level: :debug)

    @processor = Ezclaw::MessageProcessor.new(
      llm: @llm,
      memory: @memory,
      tool_registry: @registry,
      system_prompt: "You are a test bot.",
      logger: @logger
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_simple_text_response
    @llm.responses = [{ role: "assistant", content: "Hello!", tool_calls: nil }]
    result = @processor.process(user_message: "Hi")
    assert_equal "Hello!", result[:content]
  end

  def test_tool_call_loop
    @llm.responses = [
      { role: "assistant", content: nil, tool_calls: [{ id: "c1", name: "echo", arguments: { "text" => "hello" } }] },
      { role: "assistant", content: "Tool said: hello", tool_calls: nil }
    ]

    echo_tool = Class.new(Ezclaw::Tool) do
      desc "Echo text"
      param :text, type: :string, required: true
      def call(text:); text; end
    end
    @registry.register("echo", echo_tool)

    result = @processor.process(user_message: "Echo hello")
    assert_equal "Tool said: hello", result[:content]
  end

  def test_includes_conversation_history
    @llm.responses = [{ role: "assistant", content: "I see the context.", tool_calls: nil }]
    history = [
      { role: "user", content: "First message" },
      { role: "assistant", content: "First reply" }
    ]
    result = @processor.process(user_message: "Follow up", conversation_history: history)
    assert_equal "I see the context.", result[:content]
  end

  def test_user_message_is_plain_string_when_no_images
    @llm.responses = [{ role: "assistant", content: "ok", tool_calls: nil }]
    @processor.process(user_message: "Hi")
    user_msg = @llm.last_messages.last
    assert_equal "user", user_msg[:role]
    assert_equal "Hi", user_msg[:content]
  end

  def test_images_produce_multimodal_user_content
    @llm.responses = [{ role: "assistant", content: "I see it", tool_calls: nil }]
    images = [{ type: "image", media_type: "image/png", data: "QUJD" }]
    @processor.process(user_message: "what is this?", images: images)

    user_msg = @llm.last_messages.last
    assert_equal "user", user_msg[:role]
    assert_equal(
      [
        { type: "text", text: "what is this?" },
        { type: "image", media_type: "image/png", data: "QUJD" }
      ],
      user_msg[:content]
    )
  end

  def test_image_only_message_omits_empty_text_block
    @llm.responses = [{ role: "assistant", content: "I see it", tool_calls: nil }]
    images = [{ type: "image", media_type: "image/jpeg", data: "ZZZ" }]
    @processor.process(user_message: "", images: images)

    user_msg = @llm.last_messages.last
    assert_equal(
      [{ type: "image", media_type: "image/jpeg", data: "ZZZ" }],
      user_msg[:content]
    )
  end

  def test_max_tool_iterations
    @llm.responses = Array.new(20) { { role: "assistant", content: nil, tool_calls: [{ id: "c1", name: "echo", arguments: { "text" => "x" } }] } }
    echo_tool = Class.new(Ezclaw::Tool) do
      desc "Echo"
      param :text, type: :string, required: true
      def call(text:); text; end
    end
    @registry.register("echo", echo_tool)

    result = @processor.process(user_message: "loop forever")
    assert result[:content]
  end

  def wrapup_processor(max_tool_iterations: 3)
    echo_tool = Class.new(Ezclaw::Tool) do
      desc "Echo"
      param :text, type: :string, required: true
      def call(text:); text; end
    end
    @registry.register("echo", echo_tool)

    Ezclaw::MessageProcessor.new(
      llm: @llm,
      memory: @memory,
      tool_registry: @registry,
      system_prompt: "You are a test bot.",
      logger: @logger,
      max_tool_iterations: max_tool_iterations
    )
  end

  # Hitting the cap mid-investigation must not drop the work with a raw
  # "tool call limit" message: the processor makes one final no-tools call
  # so the model turns whatever it found into an answer.
  def test_max_tool_iterations_triggers_wrapup_call
    processor = wrapup_processor(max_tool_iterations: 3)
    # Exactly 3 canned tool-call responses — the 4th call (the wrap-up) hits
    # FakeLLM's fallback ("default response", no tool_calls).
    @llm.responses = Array.new(3) { |i|
      { role: "assistant", content: nil, tool_calls: [{ id: "c#{i}", name: "echo", arguments: { "text" => "x" } }] }
    }
    result = processor.process(user_message: "loop forever")

    assert_equal "default response", result[:content]
    assert_equal [], @llm.last_tools

    # The wrap-up request must not replay the capped turn's unexecuted
    # tool_calls (orphaned tool_use blocks get rejected by the API), and it
    # carries the wrap-up instruction as the final user message.
    final_messages = @llm.last_messages
    assert_equal "user", final_messages.last[:role]
    assert_match(/out of tool calls/i, final_messages.last[:content])
    assert_nil final_messages[-2][:tool_calls]
  end

  # If the wrap-up call itself fails, fall back to the static message rather
  # than raising out of the processing loop.
  def test_wrapup_failure_falls_back_to_limit_message
    raising_llm = Class.new(FakeLLM) do
      def chat(messages:, tools: [], **)
        raise "boom" if tools.empty?
        super
      end
    end.new
    @llm = raising_llm
    processor = wrapup_processor(max_tool_iterations: 2)
    @llm.responses = Array.new(5) { |i|
      { role: "assistant", content: nil, tool_calls: [{ id: "c#{i}", name: "echo", arguments: { "text" => "x" } }] } }

    result = processor.process(user_message: "loop forever")
    assert_equal "I've reached my tool call limit. Here's what I have so far.", result[:content]
  end

  def test_cron_source_is_unattended
    @llm.responses = [{ role: "assistant", content: "brief", tool_calls: nil }]
    @processor.process(user_message: "go", source: "cron:heartbeat")
    assert_equal false, @llm.last_interactive
  end

  def test_slack_source_is_interactive
    @llm.responses = [{ role: "assistant", content: "hi", tool_calls: nil }]
    @processor.process(user_message: "go", source: "slack")
    assert_equal true, @llm.last_interactive
  end
end
