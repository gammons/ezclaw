# frozen_string_literal: true

class FixtureGreetTool < Ezclaw::Tool
  desc "Greet someone"
  param :name, type: :string, required: true

  def call(name:)
    "Hello, #{name}!"
  end
end
