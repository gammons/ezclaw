# frozen_string_literal: true

require "fileutils"

module Ezclaw
  class Memory
    def initialize(config_dir:, data_dir:, filename:)
      @config_path = File.join(config_dir, filename)
      @data_path = File.join(data_dir, filename)
      @mutex = Mutex.new
    end

    def read
      @mutex.synchronize do
        if File.exist?(@data_path)
          File.read(@data_path)
        elsif File.exist?(@config_path)
          content = File.read(@config_path)
          FileUtils.mkdir_p(File.dirname(@data_path))
          File.write(@data_path, content)
          content
        else
          ""
        end
      end
    end

    def update(content)
      @mutex.synchronize do
        FileUtils.mkdir_p(File.dirname(@data_path))
        File.write(@data_path, content)
      end
    end
  end
end
