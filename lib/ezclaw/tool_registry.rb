# frozen_string_literal: true

module Ezclaw
  class ToolRegistry
    def initialize
      @tools = {}
    end

    def register(name, klass)
      @tools[name] = klass
    end

    def find(name)
      @tools[name]
    end

    def load_directory(dir)
      return unless dir && Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.rb")).each do |file|
        before = ObjectSpace.each_object(Class).select { |c| c < Ezclaw::Tool }.to_set
        Kernel.load(file)
        after = ObjectSpace.each_object(Class).select { |c| c < Ezclaw::Tool }.to_set

        (after - before).each do |klass|
          register(klass.tool_name, klass)
        end
      end
    end

    def schemas
      @tools.map { |name, klass| klass.json_schema.merge(name: name) }
    end

    def execute(name, arguments)
      klass = find(name)
      return "Error: unknown tool '#{name}'" unless klass

      klass.new.execute(arguments)
    end
  end
end
