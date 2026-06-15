# frozen_string_literal: true

require "slack-ruby-client"
require "faye/websocket"
require "eventmachine"
require "fileutils"
require "json"
require "net/http"
require "uri"

module Ezclaw
  class SlackListener
    # How often to run the traffic watchdog (seconds).
    WATCHDOG_TICK_SECONDS = 30

    # How long to wait before retrying after a transient failure to obtain
    # the Socket Mode WSS URL (seconds).
    WSS_URL_RETRY_SECONDS = 30

    # How long to wait before reconnecting after a close/error (seconds).
    RECONNECT_DELAY_SECONDS = 5

    # Slack file mimetypes we forward to the LLM as images. Limited to the
    # formats the Anthropic/OpenAI vision APIs accept.
    SUPPORTED_IMAGE_MIMETYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    # Skip images larger than this (bytes). Anthropic rejects images above ~5MB
    # of base64, so we guard on the raw size Slack reports.
    MAX_IMAGE_BYTES = 5 * 1024 * 1024

    # watchdog_seconds: how long to wait between Slack events before forcing a
    # reconnect. Default 1800 (30 min). The 90s default we shipped originally
    # was too aggressive — Slack's Socket Mode is intentionally idle during
    # quiet periods (protocol-level pings handled by faye-websocket don't
    # trigger ws.on :message), so a 90s threshold caused idle bots like Nex to
    # disconnect every ~120s, losing events that arrived during the reconnect
    # gap. 1800s is well below Slack's own ~60-min disconnect-envelope cadence
    # while still catching the "silent for hours" failure mode the watchdog
    # was originally designed to fix.
    def initialize(processor:, config:, logger:, heartbeat_path: nil, watchdog_seconds: 1800)
      @processor = processor
      @config = config
      @logger = logger
      @bot_user_id = nil
      @heartbeat_path = heartbeat_path
      @watchdog_seconds = watchdog_seconds
      @last_event_at = nil
      @reconnect_pending = false
      @current_ws = nil

      @web_client = Slack::Web::Client.new(token: ENV.fetch("SLACK_BOT_TOKEN"))
      @app_token = ENV.fetch("SLACK_APP_TOKEN")
    end

    def start
      @logger.info("slack", "Connecting to Slack in Socket Mode...")
      fetch_bot_identity
      touch_heartbeat # mark alive at startup so liveness probe doesn't fire during initial connect

      # Run EventMachine in a separate thread so it doesn't block
      @em_thread = Thread.new do
        EM.run do
          connect_socket_mode
          start_traffic_watchdog
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
      clear_reconnect_pending

      wss_url = obtain_wss_url
      unless wss_url
        @logger.error("slack", "Could not obtain Socket Mode WSS URL, retrying in #{WSS_URL_RETRY_SECONDS}s")
        schedule_reconnect(:wss_url_failed, delay: WSS_URL_RETRY_SECONDS) { connect_socket_mode }
        return
      end

      @logger.info("slack", "Connecting to Socket Mode WSS...")
      ws = Faye::WebSocket::Client.new(wss_url)
      @current_ws = ws

      ws.on :open do |_event|
        @logger.info("slack", "Socket Mode connected")
        record_event
        touch_heartbeat
      end

      ws.on :message do |event|
        record_event
        touch_heartbeat
        handle_envelope(ws, event.data)
      end

      ws.on :error do |event|
        message = event.respond_to?(:message) ? event.message : event.inspect
        @logger.warn("slack", "Socket Mode error: #{message}")
        schedule_reconnect(:error) { connect_socket_mode }
      end

      ws.on :close do |event|
        @logger.warn("slack", "Socket Mode disconnected (code=#{event.code}). Reconnecting in #{RECONNECT_DELAY_SECONDS}s...")
        @current_ws = nil
        schedule_reconnect(:close) { connect_socket_mode }
      end
    end

    # Returns :scheduled if a new reconnect was queued, :skipped if one was
    # already pending. Reentrant from both :error and :close handlers.
    def schedule_reconnect(reason, delay: RECONNECT_DELAY_SECONDS, &block)
      if @reconnect_pending
        @logger.debug("slack", "Reconnect already pending; skipping (#{reason})")
        return :skipped
      end

      @reconnect_pending = true
      if defined?(EM) && EM.reactor_running?
        EM.add_timer(delay) { block.call }
      else
        # Test path: caller drives the block manually after inspecting state.
      end
      :scheduled
    end

    def clear_reconnect_pending
      @reconnect_pending = false
    end

    def start_traffic_watchdog
      EM.add_periodic_timer(WATCHDOG_TICK_SECONDS) do
        next unless traffic_stale?

        @logger.warn("slack", "No Socket Mode traffic for >#{@watchdog_seconds}s; closing socket to force reconnect")
        ws = @current_ws
        if ws
          # Closing the socket triggers ws.on :close which schedules a reconnect.
          begin
            ws.close
          rescue => e
            @logger.warn("slack", "Error closing stale socket: #{e.class}: #{e.message}")
            schedule_reconnect(:watchdog_close_failed) { connect_socket_mode }
          end
        else
          # No socket at all — kick a reconnect directly.
          schedule_reconnect(:watchdog_no_socket) { connect_socket_mode }
        end
        # Reset so we don't fire the watchdog repeatedly while reconnect is in flight.
        @last_event_at = Time.now
      end
    end

    def traffic_stale?
      return false unless @last_event_at

      Time.now - @last_event_at > @watchdog_seconds
    end

    def record_event
      @last_event_at = Time.now
    end

    def touch_heartbeat
      return unless @heartbeat_path

      FileUtils.mkdir_p(File.dirname(@heartbeat_path))
      FileUtils.touch(@heartbeat_path)
    rescue => e
      @logger.warn("slack", "Could not update heartbeat file #{@heartbeat_path}: #{e.class}: #{e.message}")
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

      # Slack delivers BOTH a `message` event AND an `app_mention` event for
      # every channel @mention of the bot. Drop the `message` copy so we
      # process each mention exactly once. DMs are NOT subject to this —
      # Slack does not fire `app_mention` in DMs, so the `message` event is
      # the only copy and must be processed. Channel messages that don't
      # mention the bot (thread replies, etc.) also have no `app_mention`
      # twin and must continue to flow through.
      return if type == "message" && !is_dm && mentioned?(text)

      return unless allowed_channel?(channel_id, is_dm)

      if requires_mention?(channel_id, is_dm) && !mentioned?(text)
        # Always respond in threads the bot started (no mention needed)
        is_own_thread = event["thread_ts"] && event["thread_ts"] != event["ts"] &&
                        bot_owns_thread?(channel_id, event["thread_ts"])
        return unless is_own_thread
      end

      # If someone else is specifically mentioned (but not us), stay quiet --
      # the user is talking to that person, not the bot
      if mentions_other_user?(text) && !mentioned?(text)
        @logger.debug("slack", "Skipping: message mentions another user, not us")
        return
      end

      clean_text = text.gsub(/<@#{@bot_user_id}>/, "").strip

      # Detect image attachments cheaply (no network) so we know whether an
      # image-only message should still be processed. The actual download
      # happens in the background thread below to avoid blocking the reactor.
      img_files = image_files(event)
      return if clean_text.empty? && img_files.empty?

      @logger.info("slack", "Message from #{event['user']} in #{channel_id}: #{clean_text[0..80]}#{img_files.empty? ? '' : " [#{img_files.length} image(s)]"}")

      # Process in a thread to not block the EventMachine reactor
      message_ts = event["ts"]
      Thread.new do
        add_reaction("eyes", channel_id, message_ts)

        # Status callback for assistant thread status indicator
        status_cb = ->(status) { set_thread_status(channel_id, thread_ts, status) }

        history = fetch_thread_history(channel_id, thread_ts, message_ts)
        images = img_files.map { |f| download_image(f) }.compact

        begin
          result = @processor.process(
            user_message: clean_text,
            conversation_history: history,
            images: images,
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

    def mentions_other_user?(text)
      # Check if text contains any @mention that isn't our bot
      mentions = text.scan(/<@(U[A-Z0-9]+)>/).flatten
      return false if mentions.empty?

      mentions.any? { |uid| uid != @bot_user_id }
    end

    def bot_owns_thread?(channel_id, thread_ts)
      return false unless @bot_user_id

      response = @web_client.conversations_replies(channel: channel_id, ts: thread_ts, limit: 1)
      parent = response["messages"]&.first
      parent && parent["user"] == @bot_user_id
    rescue => e
      @logger.debug("slack", "Could not check thread ownership: #{e.message}")
      false
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
            text = m["text"] || ""
            images = image_files(m).map { |f| download_image(f) }.compact
            content = if images.any?
              blocks = []
              blocks << { type: "text", text: text } unless text.strip.empty?
              blocks.concat(images)
              blocks
            else
              text
            end
            { role: role, content: content }
          }
      rescue => e
        @logger.warn("slack", "Could not fetch thread history: #{e.message}")
        []
      end
    end

    # Returns the subset of a Slack event's `files` that are images we can
    # forward to the LLM. Cheap — no network, just mimetype/size filtering.
    def image_files(event)
      files = event["files"]
      return [] unless files.is_a?(Array)

      files.select do |f|
        SUPPORTED_IMAGE_MIMETYPES.include?(f["mimetype"]) &&
          (f["size"].nil? || f["size"] <= MAX_IMAGE_BYTES)
      end
    end

    # Downloads a Slack file's bytes (authenticated, since url_private requires
    # the bot token) and returns a normalized image block, or nil on failure.
    def download_image(file)
      url = file["url_private_download"] || file["url_private"]
      return nil unless url

      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{ENV.fetch('SLACK_BOT_TOKEN')}"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      response = http.request(req)

      unless response.is_a?(Net::HTTPSuccess)
        @logger.warn("slack", "Could not download image #{file['id']}: HTTP #{response.code}")
        return nil
      end

      body = response.body
      if body.bytesize > MAX_IMAGE_BYTES
        @logger.warn("slack", "Skipping image #{file['id']}: #{body.bytesize} bytes exceeds limit")
        return nil
      end

      {
        type: "image",
        media_type: file["mimetype"],
        data: [body].pack("m0")
      }
    rescue => e
      @logger.warn("slack", "Error downloading image #{file['id']}: #{e.class}: #{e.message}")
      nil
    end
  end
end
