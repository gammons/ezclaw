# frozen_string_literal: true

module Grantclaw
  class MessageProcessor
    DEFAULT_MAX_TOOL_ITERATIONS = 30

    def initialize(llm:, memory:, tool_registry:, system_prompt:, logger:, max_tool_iterations: nil)
      @llm = llm
      @memory = memory
      @registry = tool_registry
      @system_prompt = system_prompt
      @logger = logger
      @max_tool_iterations = max_tool_iterations || DEFAULT_MAX_TOOL_ITERATIONS
    end

    # on_status: optional callback proc that receives a status string
    #   e.g., "Thinking...", "Running tool: stripe", "Generating response..."
    #   Called with nil to clear status.
    def process(user_message:, conversation_history: [], source: "unknown", on_status: nil)
      messages = build_messages(user_message, conversation_history)
      tools = @registry.schemas

      iterations = 0
      loop do
        iterations += 1
        on_status&.call("Thinking...")
        @logger.info("llm", "Request to #{source} | tools=#{tools.length}")

        response = @llm.chat(messages: messages, tools: tools)

        if response[:usage]
          @logger.info("llm", "Usage: in=#{response[:usage][:input]} out=#{response[:usage][:output]}")
        end

        if response[:tool_calls].nil? || response[:tool_calls].empty?
          @logger.info("llm", "Response: text")
          on_status&.call(nil)
          return { role: "assistant", content: response[:content] }
        end

        if iterations >= @max_tool_iterations
          @logger.warn("llm", "Hit max tool iterations (#{@max_tool_iterations}), bailing out")
          on_status&.call(nil)
          return { role: "assistant", content: response[:content] || "I've reached my tool call limit. Here's what I have so far." }
        end

        messages << { role: "assistant", content: response[:content], tool_calls: response[:tool_calls] }

        response[:tool_calls].each do |tc|
          on_status&.call("Running tool: #{tc[:name]}")
          @logger.info("tool", "#{tc[:name]}(#{tc[:arguments].inspect})")
          result = @registry.execute(tc[:name], tc[:arguments])
          @logger.info("tool", "#{tc[:name]} -> #{result.to_s[0..200]}")
          result_str = result.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
          messages << { role: "tool", tool_call_id: tc[:id], content: result_str }
        end

        on_status&.call("Generating response...")
      end
    end

    private

    def build_messages(user_message, conversation_history)
      memory_content = @memory.read
      full_system = [@system_prompt, memory_content].reject(&:empty?).join("\n---\n")

      messages = [{ role: "system", content: full_system }]
      messages.concat(conversation_history) if conversation_history.any?
      messages << { role: "user", content: user_message }
      messages
    end
  end
end
