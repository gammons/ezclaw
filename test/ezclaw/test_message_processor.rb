# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class FakeLLM < Ezclaw::LLM::Base
  attr_accessor :responses

  def initialize
    super(model: "fake", max_tokens: 100)
    @responses = []
    @call_count = 0
  end

  def chat(messages:, tools: [], model: nil)
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
