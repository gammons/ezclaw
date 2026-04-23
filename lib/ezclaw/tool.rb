# frozen_string_literal: true

module Ezclaw
  class Tool
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@params, [])
        subclass.instance_variable_set(:@description, "")
      end

      def desc(text)
        @description = text
      end

      def param(name, type: :string, desc: nil, enum: nil, required: false, default: nil)
        @params << { name: name, type: type, desc: desc, enum: enum, required: required, default: default }
      end

      def tool_description
        @description
      end

      def tool_params
        @params
      end

      def tool_name
        name_str = self.name || self.to_s
        # "GreetTool" -> "greet", "SlackPostTool" -> "slack_post"
        name_str.split("::").last
          .gsub(/Tool$/, "")
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
      end

      def json_schema
        properties = {}
        required = []

        tool_params.each do |p|
          prop = { type: p[:type].to_s }
          prop[:description] = p[:desc] if p[:desc]
          prop[:enum] = p[:enum] if p[:enum]
          properties[p[:name].to_s] = prop
          required << p[:name].to_s if p[:required]
        end

        {
          name: tool_name,
          description: tool_description,
          parameters: {
            type: "object",
            properties: properties,
            required: required
          }
        }
      end
    end

    def execute(arguments)
      kwargs = {}
      self.class.tool_params.each do |p|
        key = p[:name]
        str_key = key.to_s
        if arguments.key?(str_key)
          kwargs[key] = arguments[str_key]
        elsif arguments.key?(key)
          kwargs[key] = arguments[key]
        elsif p[:default]
          kwargs[key] = p[:default]
        end
      end
      result = call(**kwargs)
      if result.is_a?(String)
        result.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      else
        JSON.generate(result)
      end
    rescue => e
      "Error executing #{self.class.tool_name}: #{e.message}"
    end

    def call(**kwargs)
      raise NotImplementedError, "#{self.class}#call not implemented"
    end
  end
end
