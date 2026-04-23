# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "uri"

module Ezclaw
  module Tools
    class WebFetchTool < Tool
      desc "Fetch the contents of a URL. Returns the response body as text. Useful for reading web pages, APIs, or any HTTP endpoint."
      param :url, type: :string, desc: "The URL to fetch (must include https:// or http://)", required: true
      param :method, type: :string, desc: "HTTP method", enum: %w[get post], default: "get"
      param :headers, type: :object, desc: "Optional HTTP headers as key-value pairs"
      param :body, type: :string, desc: "Optional request body (for POST requests)"

      MAX_BODY_SIZE = 50_000 # characters

      def call(url:, method: "get", headers: nil, body: nil)
        uri = URI.parse(url)
        unless %w[http https].include?(uri.scheme)
          return "Error: URL must start with http:// or https://"
        end

        conn = Faraday.new(url: url) do |f|
          f.options.timeout = 30
          f.options.open_timeout = 10
          f.use Faraday::FollowRedirects::Middleware, limit: 5
          f.adapter Faraday.default_adapter
        end

        response = case method.downcase
        when "post"
          conn.post do |req|
            (headers || {}).each { |k, v| req.headers[k.to_s] = v.to_s }
            req.body = body if body
          end
        else
          conn.get do |req|
            (headers || {}).each { |k, v| req.headers[k.to_s] = v.to_s }
          end
        end

        result = "HTTP #{response.status}\n"
        content = response.body.to_s
        if content.length > MAX_BODY_SIZE
          result += content[0...MAX_BODY_SIZE] + "\n\n[Truncated — #{content.length} total characters]"
        else
          result += content
        end
        result
      rescue Faraday::TimeoutError
        "Error: Request timed out after 30 seconds"
      rescue Faraday::ConnectionFailed => e
        "Error: Connection failed — #{e.message}"
      rescue => e
        "Error fetching URL: #{e.class}: #{e.message}"
      end
    end
  end
end
