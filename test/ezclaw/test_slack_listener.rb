# frozen_string_literal: true

require_relative "../test_helper"
require "ezclaw/slack_listener"
require "tmpdir"

class TestSlackListener < Minitest::Test
  def setup
    @prev_bot_token = ENV["SLACK_BOT_TOKEN"]
    @prev_app_token = ENV["SLACK_APP_TOKEN"]
    ENV["SLACK_BOT_TOKEN"] = "xoxb-test"
    ENV["SLACK_APP_TOKEN"] = "xapp-test"

    @output = StringIO.new
    @logger = Ezclaw::Log.new(output: @output, level: :debug)
    @config = Object.new
    def @config.slack
      { "channels" => [], "dm_policy" => "open" }
    end
  end

  def teardown
    ENV["SLACK_BOT_TOKEN"] = @prev_bot_token
    ENV["SLACK_APP_TOKEN"] = @prev_app_token
  end

  def build_listener(heartbeat_path: nil, watchdog_seconds: 90)
    Ezclaw::SlackListener.new(
      processor: Object.new,
      config: @config,
      logger: @logger,
      heartbeat_path: heartbeat_path,
      watchdog_seconds: watchdog_seconds
    )
  end

  def test_touch_heartbeat_creates_file_when_path_configured
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".slack_alive")
      listener = build_listener(heartbeat_path: path)
      listener.send(:touch_heartbeat)
      assert File.exist?(path), "expected heartbeat file to be created at #{path}"
    end
  end

  def test_touch_heartbeat_updates_mtime_on_subsequent_calls
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".slack_alive")
      listener = build_listener(heartbeat_path: path)
      listener.send(:touch_heartbeat)
      old_mtime = File.mtime(path)
      sleep 1.1
      listener.send(:touch_heartbeat)
      new_mtime = File.mtime(path)
      assert new_mtime > old_mtime, "expected mtime to advance on second touch"
    end
  end

  def test_touch_heartbeat_is_noop_when_path_nil
    listener = build_listener(heartbeat_path: nil)
    # Should not raise
    listener.send(:touch_heartbeat)
  end

  def test_touch_heartbeat_swallows_filesystem_errors
    listener = build_listener(heartbeat_path: "/proc/cannot-write-here/.slack_alive")
    # Must not raise — heartbeat failure should never crash the listener
    listener.send(:touch_heartbeat)
    assert_match(/heartbeat/i, @output.string)
  end

  def test_record_event_updates_last_event_timestamp
    listener = build_listener
    before = Time.now
    listener.send(:record_event)
    after = Time.now
    last = listener.instance_variable_get(:@last_event_at)
    refute_nil last
    assert last >= before
    assert last <= after
  end

  def test_traffic_stale_returns_true_when_no_traffic_for_too_long
    listener = build_listener(watchdog_seconds: 60)
    listener.instance_variable_set(:@last_event_at, Time.now - 120)
    assert listener.send(:traffic_stale?), "expected traffic to be considered stale"
  end

  def test_traffic_stale_returns_false_when_recent_traffic
    listener = build_listener(watchdog_seconds: 60)
    listener.instance_variable_set(:@last_event_at, Time.now - 5)
    refute listener.send(:traffic_stale?), "expected traffic not to be stale"
  end

  def test_traffic_stale_returns_false_before_first_event
    listener = build_listener(watchdog_seconds: 60)
    refute listener.send(:traffic_stale?), "expected not stale before any event"
  end

  def test_schedule_reconnect_is_debounced
    listener = build_listener
    # First call should mark reconnect pending and yield "scheduled"
    assert_equal :scheduled, listener.send(:schedule_reconnect, :test) { :ran }
    # Second call while reconnect is pending should be skipped
    assert_equal :skipped, listener.send(:schedule_reconnect, :test) { :ran }
  end

  def test_schedule_reconnect_can_be_called_again_after_clear
    listener = build_listener
    assert_equal :scheduled, listener.send(:schedule_reconnect, :test) { :ran }
    listener.send(:clear_reconnect_pending)
    assert_equal :scheduled, listener.send(:schedule_reconnect, :test) { :ran }
  end

  # --- handle_event: dedupe `message` vs `app_mention` for channel mentions ---
  #
  # Slack delivers BOTH a `message` event AND an `app_mention` event for every
  # channel @mention of the bot. Without a gate, the bot processes the same
  # user input twice — sending two replies and performing tool actions twice.
  # See: https://api.slack.com/events/app_mention

  BOT_USER_ID = "U0BOTID"
  CHANNEL_ID = "C0CHAN"

  def build_channel_listener
    listener = build_listener
    def @config.slack
      {
        "channels" => [
          { "id" => "C0CHAN", "name" => "test", "require_mention" => true }
        ],
        "dm_policy" => "open"
      }
    end
    listener.instance_variable_set(:@bot_user_id, BOT_USER_ID)
    # Stub processor so the background Thread.new in handle_event has something
    # benign to call. The log line we assert on is emitted synchronously
    # BEFORE the thread is spawned, so the thread's behavior doesn't affect
    # the assertion outcome — but the stub keeps stderr clean.
    processor = Object.new
    def processor.process(**)
      { content: "" }
    end
    listener.instance_variable_set(:@processor, processor)
    # Stub web client so reactions/messages from the background thread don't
    # raise loudly. All methods become no-ops returning nil.
    web = Object.new
    def web.method_missing(*) ; nil; end
    def web.respond_to_missing?(*) ; true; end
    listener.instance_variable_set(:@web_client, web)
    listener
  end

  def channel_mention_message_event
    {
      "type" => "message",
      "user" => "U0HUMAN",
      "channel" => CHANNEL_ID,
      "channel_type" => "channel",
      "text" => "<@#{BOT_USER_ID}> please do the thing",
      "ts" => "1700000000.000100"
    }
  end

  def channel_app_mention_event
    {
      "type" => "app_mention",
      "user" => "U0HUMAN",
      "channel" => CHANNEL_ID,
      "text" => "<@#{BOT_USER_ID}> please do the thing",
      "ts" => "1700000000.000100"
    }
  end

  def test_skips_message_event_when_bot_is_mentioned_in_channel
    # Slack will ALSO deliver an `app_mention` event for the same user input.
    # The `message` copy must be skipped to avoid double-processing.
    listener = build_channel_listener
    listener.send(:handle_event, channel_mention_message_event)
    refute_match(
      /Message from/, @output.string,
      "Expected `message` event with bot @mention in channel to be skipped " \
      "(app_mention will fire too), but it was processed."
    )
  end

  def test_processes_app_mention_event_in_channel
    listener = build_channel_listener
    listener.send(:handle_event, channel_app_mention_event)
    assert_match(/Message from U0HUMAN in #{CHANNEL_ID}/, @output.string,
                 "Expected `app_mention` event to be processed.")
  end

  def test_processes_message_event_in_dm_even_with_mention_token
    # DMs only fire `message` events (Slack does NOT fire `app_mention` in
    # DMs), so we must process the `message` copy here.
    listener = build_channel_listener
    dm_event = channel_mention_message_event.merge(
      "channel" => "D0DM", "channel_type" => "im"
    )
    listener.send(:handle_event, dm_event)
    assert_match(/Message from U0HUMAN/, @output.string,
                 "Expected DM `message` event to be processed.")
  end

  def test_processes_message_event_in_channel_without_mention_falls_through
    # Plain channel message that doesn't mention the bot: app_mention does NOT
    # fire, so the `message` event is the ONLY copy. We must process it
    # (subject to the existing thread-ownership / require_mention rules).
    listener = build_channel_listener
    # Allow the channel without requiring mention so handle_event proceeds.
    def @config.slack
      {
        "channels" => [
          { "id" => "C0CHAN", "name" => "test", "require_mention" => false }
        ],
        "dm_policy" => "open"
      }
    end
    plain_event = channel_mention_message_event.merge(
      "text" => "hey team, status check"
    )
    listener.send(:handle_event, plain_event)
    assert_match(/Message from U0HUMAN/, @output.string,
                 "Expected non-mentioning `message` event to be processed.")
  end
end
