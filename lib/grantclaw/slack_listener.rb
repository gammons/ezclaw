# frozen_string_literal: true

require "slack-ruby-client"
require "faye/websocket"
require "eventmachine"
require "json"
require "net/http"
require "uri"

module Grantclaw
  class SlackListener
    def initialize(processor:, config:, logger:)
      @processor = processor
      @config = config
      @logger = logger
      @bot_user_id = nil

      @web_client = Slack::Web::Client.new(token: ENV.fetch("SLACK_BOT_TOKEN"))
      @app_token = ENV.fetch("SLACK_APP_TOKEN")
    end

    def start
      @logger.info("slack", "Connecting to Slack in Socket Mode...")
      fetch_bot_identity

      # Run EventMachine in a separate thread so it doesn't block
      @em_thread = Thread.new do
        EM.run do
          connect_socket_mode
        end
      end

      @logger.info("slack", "Slack listener started")
    end

    def stop
      @logger.info("slack", "Slack listener stopping")
      EM.stop if EM.reactor_running?
      @em_thread&.join(5)
    end

    def web_client
      @web_client
    end

    private

    def connect_socket_mode
      wss_url = obtain_wss_url
      unless wss_url
        @logger.error("slack", "Could not obtain Socket Mode WSS URL")
        return
      end

      @logger.info("slack", "Connecting to Socket Mode WSS...")
      ws = Faye::WebSocket::Client.new(wss_url)

      ws.on :open do |_event|
        @logger.info("slack", "Socket Mode connected")
      end

      ws.on :message do |event|
        handle_envelope(ws, event.data)
      end

      ws.on :close do |event|
        @logger.warn("slack", "Socket Mode disconnected (code=#{event.code}). Reconnecting in 5s...")
        EM.add_timer(5) { connect_socket_mode }
      end
    end

    def obtain_wss_url
      uri = URI("https://slack.com/api/apps.connections.open")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@app_token}"
      req["Content-Type"] = "application/x-www-form-urlencoded"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      response = http.request(req)
      data = JSON.parse(response.body)

      if data["ok"]
        data["url"]
      else
        @logger.error("slack", "apps.connections.open failed: #{data['error']}")
        nil
      end
    rescue => e
      @logger.error("slack", "Failed to obtain WSS URL: #{e.message}")
      nil
    end

    def handle_envelope(ws, raw)
      envelope = JSON.parse(raw)
      envelope_id = envelope["envelope_id"]

      # Acknowledge immediately
      ws.send(JSON.generate({ envelope_id: envelope_id })) if envelope_id

      type = envelope["type"]
      case type
      when "events_api"
        event = envelope.dig("payload", "event")
        handle_event(event) if event
      when "slash_commands"
        # Ignore for now
      when "interactive"
        # Ignore for now
      when "disconnect"
        @logger.info("slack", "Received disconnect request, will reconnect")
      end
    rescue => e
      @logger.error("slack", "Error handling envelope: #{e.class}: #{e.message}")
    end

    def handle_event(event)
      type = event["type"]
      return unless type == "message" || type == "app_mention"

      return if event["user"] == @bot_user_id
      return if event["subtype"] && event["subtype"] != "message_replied"

      channel_id = event["channel"]
      text = event["text"] || ""
      thread_ts = event["thread_ts"] || event["ts"]
      is_dm = event["channel_type"] == "im"

      return unless allowed_channel?(channel_id, is_dm)

      if requires_mention?(channel_id, is_dm) && !mentioned?(text)
        return
      end

      clean_text = text.gsub(/<@#{@bot_user_id}>/, "").strip
      return if clean_text.empty?

      @logger.info("slack", "Message from #{event['user']} in #{channel_id}: #{clean_text[0..80]}")

      # Process in a thread to not block the EventMachine reactor
      message_ts = event["ts"]
      Thread.new do
        add_reaction("eyes", channel_id, message_ts)

        # Status callback for assistant thread status indicator
        status_cb = ->(status) { set_thread_status(channel_id, thread_ts, status) }

        history = fetch_thread_history(channel_id, thread_ts, message_ts)

        begin
          result = @processor.process(
            user_message: clean_text,
            conversation_history: history,
            source: "slack",
            on_status: status_cb
          )

          remove_reaction("eyes", channel_id, message_ts)

          formatted = SlackFormatter.markdown_to_mrkdwn(result[:content])
          @web_client.chat_postMessage(
            channel: channel_id,
            text: formatted,
            thread_ts: thread_ts
          )
        rescue => e
          @logger.error("slack", "Error processing message: #{e.class}: #{e.message}")
          remove_reaction("eyes", channel_id, message_ts)
          set_thread_status(channel_id, thread_ts, nil)
          begin
            @web_client.chat_postMessage(
              channel: channel_id,
              text: "Sorry, I encountered an error processing your message.",
              thread_ts: thread_ts
            )
          rescue => e2
            @logger.error("slack", "Could not send error message: #{e2.message}")
          end
        end
      end
    end

    def set_thread_status(channel, thread_ts, status)
      return unless thread_ts

      @web_client.assistant_threads_setStatus(
        channel_id: channel,
        thread_ts: thread_ts,
        status: status || ""
      )
    rescue => e
      @logger.debug("slack", "Could not set thread status: #{e.message}")
    end

    def add_reaction(emoji, channel, timestamp)
      @web_client.reactions_add(name: emoji, channel: channel, timestamp: timestamp)
    rescue => e
      @logger.debug("slack", "Could not add reaction: #{e.message}")
    end

    def remove_reaction(emoji, channel, timestamp)
      @web_client.reactions_remove(name: emoji, channel: channel, timestamp: timestamp)
    rescue => e
      @logger.debug("slack", "Could not remove reaction: #{e.message}")
    end

    def fetch_bot_identity
      auth = @web_client.auth_test
      @bot_user_id = auth["user_id"]
      @logger.info("slack", "Connected as #{auth['user']} (#{@bot_user_id})")
    rescue => e
      @logger.warn("slack", "Could not fetch bot identity: #{e.message}")
    end

    def allowed_channel?(channel_id, is_dm)
      return true if is_dm && dm_policy == "open"

      channels = @config.slack.fetch("channels", [])
      channels.any? { |c| c["id"] == channel_id && c.fetch("allow", true) }
    end

    def requires_mention?(channel_id, is_dm)
      return false if is_dm

      channels = @config.slack.fetch("channels", [])
      ch = channels.find { |c| c["id"] == channel_id }
      ch&.fetch("require_mention", true) != false
    end

    def dm_policy
      @config.slack.fetch("dm_policy", "open")
    end

    def mentioned?(text)
      return false unless @bot_user_id

      text.include?("<@#{@bot_user_id}>")
    end

    def fetch_thread_history(channel, thread_ts, current_ts)
      return [] unless thread_ts && thread_ts != current_ts

      begin
        response = @web_client.conversations_replies(channel: channel, ts: thread_ts, limit: 50)
        messages = response["messages"] || []

        messages
          .reject { |m| m["ts"] == current_ts }
          .map { |m|
            role = m["user"] == @bot_user_id ? "assistant" : "user"
            { role: role, content: m["text"] || "" }
          }
      rescue => e
        @logger.warn("slack", "Could not fetch thread history: #{e.message}")
        []
      end
    end
  end
end
