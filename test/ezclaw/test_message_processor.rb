# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class FakeLLM < Ezclaw::LLM::Base
  attr_accessor :responses
  attr_reader :last_messages

  def initialize
    super(model: "fake", max_tokens: 100)
    @responses = []
    @call_count = 0
    @last_messages = nil
  end

  def chat(messages:, tools: [], model: nil)
    @last_messages = messages
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
end
