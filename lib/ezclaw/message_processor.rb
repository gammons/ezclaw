# frozen_string_literal: true

module Ezclaw
  class MessageProcessor
    DEFAULT_MAX_TOOL_ITERATIONS = 30

    TOOL_LIMIT_FALLBACK = "I've reached my tool call limit. Here's what I have so far."

    WRAP_UP_PROMPT = "You are out of tool calls for this request. Stop investigating " \
                     "and answer NOW with what you have: what you confirmed, what you " \
                     "could not confirm, and the most useful next step. Do not call any tools."

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
    def process(user_message:, conversation_history: [], images: [], source: "unknown", on_status: nil)
      messages = build_messages(user_message, conversation_history, images)
      tools = @registry.schemas
      # Cron/heartbeat work is unattended: let the LLM client retry hard.
      # Everything else is interactive and should fail fast.
      interactive = !source.to_s.start_with?("cron:")

      iterations = 0
      loop do
        iterations += 1
        on_status&.call("Thinking...")
        @logger.info("llm", "Request to #{source} | tools=#{tools.length}")

        response = @llm.chat(messages: messages, tools: tools, interactive: interactive)

        if response[:usage]
          @logger.info("llm", "Usage: in=#{response[:usage][:input]} out=#{response[:usage][:output]}")
        end

        if response[:tool_calls].nil? || response[:tool_calls].empty?
          @logger.info("llm", "Response: text")
          on_status&.call(nil)
          return { role: "assistant", content: response[:content] }
        end

        if iterations >= @max_tool_iterations
          @logger.warn("llm", "Hit max tool iterations (#{@max_tool_iterations}), requesting wrap-up")
          on_status&.call("Wrapping up...")
          return { role: "assistant", content: wrap_up(messages, response) }
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

    # The tool budget ran out mid-investigation. Give the model one final
    # no-tools call to turn whatever it found into an answer, instead of
    # dropping the work with a raw "tool call limit" message. The assistant
    # turn that triggered the cap carries unexecuted tool_calls, so only its
    # text content (if any) is appended — replaying orphaned tool_calls would
    # make the API reject the request.
    def wrap_up(messages, last_response)
      content = last_response[:content]
      messages << { role: "assistant", content: content } if content && !content.to_s.empty?
      messages << { role: "user", content: WRAP_UP_PROMPT }

      final = @llm.chat(messages: messages, tools: [])
      answer = final[:content]
      answer = nil if answer.to_s.empty?
      answer || content || TOOL_LIMIT_FALLBACK
    rescue => e
      @logger.warn("llm", "Wrap-up call failed: #{e.class}: #{e.message}")
      last_response[:content] || TOOL_LIMIT_FALLBACK
    end

    def build_messages(user_message, conversation_history, images)
      memory_content = @memory.read
      full_system = [@system_prompt, memory_content].reject(&:empty?).join("\n---\n")

      messages = [{ role: "system", content: full_system }]
      messages.concat(conversation_history) if conversation_history.any?
      messages << { role: "user", content: user_content(user_message, images) }
      messages
    end

    # When images are attached, the user turn becomes an array of normalized
    # content blocks ({ type: "text"/"image", ... }) that each LLM adapter
    # translates into its provider-specific format. With no images we keep the
    # plain-string form for backwards compatibility.
    def user_content(user_message, images)
      return user_message if images.nil? || images.empty?

      blocks = []
      blocks << { type: "text", text: user_message } unless user_message.to_s.strip.empty?
      blocks.concat(images)
      blocks
    end
  end
end
