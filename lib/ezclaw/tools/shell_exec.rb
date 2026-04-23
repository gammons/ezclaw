# frozen_string_literal: true

require "open3"

module Ezclaw
  module Tools
    class ShellExecTool < Tool
      desc "Execute a shell command and return its output. Use this for running scripts, CLI tools, curl, data processing, or any system command."
      param :command, type: :string, desc: "The shell command to execute", required: true
      param :timeout, type: :integer, desc: "Timeout in seconds (default: 60)", default: 60

      MAX_OUTPUT_SIZE = 50_000 # characters

      def call(command:, timeout: 60)
        stdout, stderr, status = nil, nil, nil

        begin
          Timeout.timeout(timeout) do
            stdout, stderr, status = Open3.capture3(command)
          end
        rescue Timeout::Error
          return "Error: Command timed out after #{timeout} seconds"
        end

        result = "Exit code: #{status.exitstatus}\n"

        unless stdout.empty?
          result += "--- STDOUT ---\n"
          result += truncate(stdout)
        end

        unless stderr.empty?
          result += "--- STDERR ---\n"
          result += truncate(stderr)
        end

        result
      end

      private

      def truncate(text)
        if text.length > MAX_OUTPUT_SIZE
          text[0...MAX_OUTPUT_SIZE] + "\n[Truncated — #{text.length} total characters]\n"
        else
          text
        end
      end
    end
  end
end
