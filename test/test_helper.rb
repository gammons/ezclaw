# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require_relative "../lib/grantclaw"

# Fixtures directory
FIXTURES_DIR = File.join(__dir__, "fixtures")

# Create a minimal bot config for tests
def minimal_config(overrides = {})
  {
    "name" => "test-bot",
    "llm" => {
      "provider" => "openrouter",
      "model" => "anthropic/claude-sonnet-4-20250514",
      "max_tokens" => 1024
    },
    "context" => {
      "system_files" => ["role.md"],
      "memory_file" => "memory.md"
    }
  }.merge(overrides)
end
