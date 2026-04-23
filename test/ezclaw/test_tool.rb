# frozen_string_literal: true

require_relative "../test_helper"

# Define a test tool inline
class GreetTool < Ezclaw::Tool
  desc "Greet a person by name"
  param :name, type: :string, desc: "Person's name", required: true
  param :style, type: :string, enum: %w[formal casual], default: "casual"

  def call(name:, style: "casual")
    if style == "formal"
      "Good day, #{name}."
    else
      "Hey #{name}!"
    end
  end
end

class TestTool < Minitest::Test
  def test_tool_description
    assert_equal "Greet a person by name", GreetTool.tool_description
  end

  def test_tool_params
    params = GreetTool.tool_params
    assert_equal 2, params.length
    assert_equal :name, params[0][:name]
    assert_equal true, params[0][:required]
    assert_equal :style, params[1][:name]
    assert_equal %w[formal casual], params[1][:enum]
  end

  def test_json_schema
    schema = GreetTool.json_schema
    assert_equal "greet", schema[:name]
    assert_equal "Greet a person by name", schema[:description]
    props = schema[:parameters][:properties]
    assert_includes props.keys, "name"
    assert_includes props.keys, "style"
    assert_equal %w[name], schema[:parameters][:required]
  end

  def test_call
    tool = GreetTool.new
    assert_equal "Hey Grant!", tool.call(name: "Grant")
    assert_equal "Good day, Grant.", tool.call(name: "Grant", style: "formal")
  end

  def test_tool_name_derived_from_class
    assert_equal "greet", GreetTool.tool_name
  end

  def test_execute_catches_errors
    bad_tool_class = Class.new(Ezclaw::Tool) do
      desc "broken"
      def call
        raise "boom"
      end
    end
    result = bad_tool_class.new.execute({})
    assert_includes result, "Error"
    assert_includes result, "boom"
  end
end
