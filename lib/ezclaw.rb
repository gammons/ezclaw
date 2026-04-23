# frozen_string_literal: true

module Ezclaw
  VERSION = "0.1.0"
end

# These will be uncommented as the corresponding files are created in later tasks:
require_relative "ezclaw/config"
require_relative "ezclaw/logger"
require_relative "ezclaw/llm/base"
require_relative "ezclaw/llm/openrouter"
require_relative "ezclaw/llm/anthropic"
require_relative "ezclaw/llm/custom"
require_relative "ezclaw/tool"
require_relative "ezclaw/tool_registry"
require_relative "ezclaw/tools/update_memory"
require_relative "ezclaw/tools/slack_post"
require_relative "ezclaw/tools/web_fetch"
require_relative "ezclaw/tools/shell_exec"
require_relative "ezclaw/slack_formatter"
require_relative "ezclaw/memory"
require_relative "ezclaw/message_processor"
require_relative "ezclaw/slack_listener"
require_relative "ezclaw/scheduler"
require_relative "ezclaw/repl"
require_relative "ezclaw/bot"
