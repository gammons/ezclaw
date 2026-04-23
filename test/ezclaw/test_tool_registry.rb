# frozen_string_literal: true

require_relative "../test_helper"

class TestToolRegistry < Minitest::Test
  def setup
    @registry = Ezclaw::ToolRegistry.new
  end

  def test_register_and_find
    klass = Class.new(Ezclaw::Tool) do
      desc "test tool"
      def call; "ok"; end
    end
    @registry.register("test", klass)
    assert_equal klass, @registry.find("test")
  end

  def test_find_returns_nil_for_unknown
    assert_nil @registry.find("nope")
  end

  def test_load_from_directory
    tools_dir = File.join(FIXTURES_DIR, "bot", "tools")
    @registry.load_directory(tools_dir)
    assert @registry.find("fixture_greet"), "Expected fixture_greet tool to be registered"
  end

  def test_schemas_returns_all_tool_schemas
    klass = Class.new(Ezclaw::Tool) do
      desc "a tool"
      param :x, type: :string, required: true
      def call(x:); x; end
    end
    Object.const_set(:SchemaDemoTool, klass)
    @registry.register("schema_demo", klass)
    schemas = @registry.schemas
    assert schemas.any? { |s| s[:name] == "schema_demo" }
  ensure
    Object.send(:remove_const, :SchemaDemoTool) if defined?(SchemaDemoTool)
  end

  def test_execute_tool
    klass = Class.new(Ezclaw::Tool) do
      desc "adder"
      param :a, type: :integer, required: true
      def call(a:); { result: a.to_i + 1 }; end
    end
    @registry.register("adder", klass)
    result = @registry.execute("adder", { "a" => 5 })
    assert_includes result, "6"
  end
end
