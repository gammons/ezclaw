# LLM Retry Backoff + Heartbeat Failure Alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LLM retries context-aware (fast-fail for interactive, aggressive backoff for unattended cron) and post a Slack alert when a heartbeat fails after exhausting retries.

**Architecture:** The shared retry helper `Ezclaw::LLM::Base#with_retries` gains an `interactive:` flag selecting one of two backoff schedules, retries only transient errors (429/5xx), and uses jittered sleeps via overridable seams. `MessageProcessor` derives `interactive` from its `source:` (`cron:*` → unattended). `Scheduler` posts a Slack alert to the bot's home channel when a triggered job raises.

**Tech Stack:** Ruby 4.0.2 (via `mise`), Minitest, WebMock. No mocha available — test doubles use `define_singleton_method` and subclassing.

**Spec:** `docs/superpowers/specs/2026-06-30-llm-retry-backoff-and-heartbeat-failure-alert-design.md`

**Running tests:**
- Single file: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_base.rb`
- Whole suite: `mise exec -- ruby -Itest -Ilib -e 'Dir.glob("test/**/test_*.rb").each { |f| require File.expand_path(f) }'`

---

### Task 1: `APIError` carries HTTP status + transient classification

**Files:**
- Modify: `lib/ezclaw/llm/base.rb:8` (the `APIError` class)
- Test: `test/ezclaw/llm/test_base.rb` (create)

- [ ] **Step 1: Write the failing test**

Create `test/ezclaw/llm/test_base.rb`:

```ruby
# frozen_string_literal: true

require_relative "../../test_helper"

class TestLLMBaseAPIError < Minitest::Test
  def test_5xx_and_429_are_transient
    assert Ezclaw::LLM::APIError.new("x", status: 500).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 503).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 529).transient?
    assert Ezclaw::LLM::APIError.new("x", status: 429).transient?
  end

  def test_4xx_other_than_429_is_not_transient
    refute Ezclaw::LLM::APIError.new("x", status: 400).transient?
    refute Ezclaw::LLM::APIError.new("x", status: 401).transient?
    refute Ezclaw::LLM::APIError.new("x", status: 404).transient?
  end

  def test_nil_status_is_not_transient
    refute Ezclaw::LLM::APIError.new("x").transient?
  end

  def test_message_is_preserved
    assert_equal "boom", Ezclaw::LLM::APIError.new("boom", status: 500).message
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_base.rb`
Expected: FAIL — `ArgumentError: wrong number of arguments` (APIError doesn't accept `status:`) / `NoMethodError: transient?`.

- [ ] **Step 3: Replace the `APIError` definition**

In `lib/ezclaw/llm/base.rb`, replace line 8:

```ruby
    class APIError < StandardError; end
```

with:

```ruby
    class APIError < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end

      # Transient = worth retrying. Upstream rate-limits (429) and server
      # errors (5xx) clear on their own; other 4xx are caller bugs and must
      # fail fast.
      def transient?
        status == 429 || (status.is_a?(Integer) && status >= 500 && status < 600)
      end
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_base.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/ezclaw/llm/base.rb test/ezclaw/llm/test_base.rb
git commit -m "feat(llm): APIError carries HTTP status with transient classification"
```

---

### Task 2: Context-aware backoff in `with_retries`

**Files:**
- Modify: `lib/ezclaw/llm/base.rb:11` (`MAX_RETRIES` constant) and `lib/ezclaw/llm/base.rb:24-34` (`with_retries`)
- Test: `test/ezclaw/llm/test_base.rb` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test/ezclaw/llm/test_base.rb` (before the final `end` of the file is not needed — these are new classes at top level):

```ruby
class TestLLMBaseRetries < Minitest::Test
  # Test double: exposes with_retries, records sleeps, removes jitter for
  # deterministic assertions.
  class Retryable < Ezclaw::LLM::Base
    attr_reader :slept

    def initialize
      super(model: "fake", max_tokens: 1)
      @slept = []
    end

    def jitter(seconds) = seconds          # disable jitter in tests
    def sleep_for(seconds) = @slept << seconds

    def run(interactive:, &blk)
      with_retries(interactive: interactive, &blk)
    end
  end

  def transient = Ezclaw::LLM::APIError.new("HTTP 529: overloaded", status: 529)

  def test_interactive_uses_short_backoff
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: true) { raise transient }
    end
    assert_equal [0.2, 0.4], r.slept
  end

  def test_unattended_uses_aggressive_backoff
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: false) { raise transient }
    end
    assert_equal [5, 15, 30, 60], r.slept
  end

  def test_retries_then_succeeds
    r = Retryable.new
    calls = 0
    result = r.run(interactive: false) do
      calls += 1
      raise transient if calls < 3
      :ok
    end
    assert_equal :ok, result
    assert_equal [5, 15], r.slept  # two failures -> two sleeps
  end

  def test_non_transient_is_not_retried
    r = Retryable.new
    assert_raises(Ezclaw::LLM::APIError) do
      r.run(interactive: false) { raise Ezclaw::LLM::APIError.new("HTTP 400: bad", status: 400) }
    end
    assert_equal [], r.slept
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_base.rb`
Expected: FAIL — `with_retries` doesn't accept `interactive:`; `jitter`/`sleep_for` don't exist; schedules don't match.

- [ ] **Step 3: Rewrite the backoff implementation**

In `lib/ezclaw/llm/base.rb`, replace the `MAX_RETRIES = 3` line (line 11):

```ruby
      MAX_RETRIES = 3
```

with:

```ruby
      # Interactive: a human is waiting — fail fast (2 retries, sub-second).
      INTERACTIVE_BACKOFF = [0.2, 0.4].freeze
      # Unattended (cron/heartbeat): nobody is waiting — ride out transient
      # upstream overloads (4 retries, ~110s cumulative).
      UNATTENDED_BACKOFF = [5, 15, 30, 60].freeze
      JITTER_RATIO = 0.2
```

Then replace the `with_retries` method (lines 24-34):

```ruby
      def with_retries
        attempts = 0
        begin
          attempts += 1
          yield
        rescue APIError => e
          raise if attempts >= MAX_RETRIES
          sleep(0.1 * (2**attempts))
          retry
        end
      end
```

with:

```ruby
      def with_retries(interactive: true)
        schedule = interactive ? INTERACTIVE_BACKOFF : UNATTENDED_BACKOFF
        attempt = 0
        begin
          yield
        rescue APIError => e
          raise unless e.transient?
          raise if attempt >= schedule.length
          sleep_for(jitter(schedule[attempt]))
          attempt += 1
          retry
        end
      end

      # +/- JITTER_RATIO randomization so multiple bots don't retry in lockstep.
      def jitter(seconds)
        delta = seconds * JITTER_RATIO
        seconds + rand(-delta..delta)
      end

      # Seam so tests can capture backoff without real sleeping.
      def sleep_for(seconds)
        sleep(seconds)
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_base.rb`
Expected: PASS (all `TestLLMBaseAPIError` + `TestLLMBaseRetries` green).

- [ ] **Step 5: Commit**

```bash
git add lib/ezclaw/llm/base.rb test/ezclaw/llm/test_base.rb
git commit -m "feat(llm): context-aware retry backoff (fast interactive, aggressive cron)"
```

---

### Task 3: Wire `interactive` flag + status into the HTTP delegates

**Files:**
- Modify: `lib/ezclaw/llm/anthropic.rb:20-34`
- Modify: `lib/ezclaw/llm/openrouter.rb:20-33`
- Modify: `lib/ezclaw/llm/custom.rb:19-21`
- Test: `test/ezclaw/llm/test_openrouter.rb` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test/ezclaw/llm/test_openrouter.rb` (inside the `TestOpenRouter` class, before its final `end`):

```ruby
  def test_does_not_retry_client_error
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 400, body: "bad request")

    assert_raises(Ezclaw::LLM::APIError) do
      @adapter.chat(messages: [{ role: "user", content: "test" }])
    end
    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions", times: 1)
  end

  def test_unattended_context_retries_aggressively
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 529, body: "overloaded").times(5)

    # Stub the sleep seam so the test doesn't actually wait ~110s.
    slept = []
    @adapter.define_singleton_method(:sleep_for) { |s| slept << s }

    assert_raises(Ezclaw::LLM::APIError) do
      @adapter.chat(messages: [{ role: "user", content: "test" }], interactive: false)
    end
    assert_requested(:post, "https://openrouter.ai/api/v1/chat/completions", times: 5)
    assert_equal 4, slept.length
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_openrouter.rb`
Expected: FAIL — `chat` doesn't accept `interactive:`; 400 currently retried (times 3, not 1).

- [ ] **Step 3: Update `openrouter.rb`**

Replace the `chat` method in `lib/ezclaw/llm/openrouter.rb` (lines 20-33):

```ruby
      def chat(messages:, tools: [], model: nil)
        with_retries do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          raise APIError, "HTTP #{response.status}: #{response.body}" unless response.status == 200

          parse_response(response.body)
        end
      end
```

with:

```ruby
      def chat(messages:, tools: [], model: nil, interactive: true)
        with_retries(interactive: interactive) do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["Authorization"] = "Bearer #{@api_key}"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          unless response.status == 200
            raise APIError.new("HTTP #{response.status}: #{response.body}", status: response.status)
          end

          parse_response(response.body)
        end
      end
```

- [ ] **Step 4: Update `anthropic.rb`**

Replace the `chat` method in `lib/ezclaw/llm/anthropic.rb` (lines 20-34):

```ruby
      def chat(messages:, tools: [], model: nil)
        with_retries do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["x-api-key"] = @api_key
            req.headers["anthropic-version"] = "2023-06-01"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          raise APIError, "HTTP #{response.status}: #{response.body}" unless response.status == 200

          parse_response(response.body)
        end
      end
```

with:

```ruby
      def chat(messages:, tools: [], model: nil, interactive: true)
        with_retries(interactive: interactive) do
          body = build_request(messages, tools, model)
          response = @conn.post { |req|
            req.headers["x-api-key"] = @api_key
            req.headers["anthropic-version"] = "2023-06-01"
            req.headers["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          }

          unless response.status == 200
            raise APIError.new("HTTP #{response.status}: #{response.body}", status: response.status)
          end

          parse_response(response.body)
        end
      end
```

- [ ] **Step 5: Update `custom.rb` to forward the flag**

Replace the `chat` method in `lib/ezclaw/llm/custom.rb` (lines 19-21):

```ruby
      def chat(messages:, tools: [], model: nil)
        @delegate.chat(messages: messages, tools: tools, model: model)
      end
```

with:

```ruby
      def chat(messages:, tools: [], model: nil, interactive: true)
        @delegate.chat(messages: messages, tools: tools, model: model, interactive: interactive)
      end
```

- [ ] **Step 6: Run the LLM tests to verify they pass**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_openrouter.rb` then
`mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_anthropic.rb` then
`mise exec -- ruby -Itest -Ilib test/ezclaw/llm/test_custom.rb`
Expected: PASS for all three (existing tests + the 2 new ones).

- [ ] **Step 7: Commit**

```bash
git add lib/ezclaw/llm/anthropic.rb lib/ezclaw/llm/openrouter.rb lib/ezclaw/llm/custom.rb test/ezclaw/llm/test_openrouter.rb
git commit -m "feat(llm): thread interactive flag and HTTP status into delegates"
```

---

### Task 4: Derive `interactive` from `source` in `MessageProcessor`

**Files:**
- Modify: `lib/ezclaw/message_processor.rb:19-29`
- Test: `test/ezclaw/test_message_processor.rb:6-20` (FakeLLM) and append a new test

- [ ] **Step 1: Update `FakeLLM` to accept and record the flag, then write the failing test**

In `test/ezclaw/test_message_processor.rb`, replace the `FakeLLM#chat` method (lines 15-19):

```ruby
  def chat(messages:, tools: [], model: nil)
    resp = @responses[@call_count] || { role: "assistant", content: "default response", tool_calls: nil }
    @call_count += 1
    resp
  end
```

with:

```ruby
  attr_reader :last_interactive

  def chat(messages:, tools: [], model: nil, interactive: true)
    @last_interactive = interactive
    resp = @responses[@call_count] || { role: "assistant", content: "default response", tool_calls: nil }
    @call_count += 1
    resp
  end
```

Then append this test inside `TestMessageProcessor` (before its final `end`):

```ruby
  def test_cron_source_is_unattended
    @llm.responses = [{ role: "assistant", content: "brief", tool_calls: nil }]
    @processor.process(user_message: "go", source: "cron:heartbeat")
    assert_equal false, @llm.last_interactive
  end

  def test_slack_source_is_interactive
    @llm.responses = [{ role: "assistant", content: "hi", tool_calls: nil }]
    @processor.process(user_message: "go", source: "slack")
    assert_equal true, @llm.last_interactive
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/test_message_processor.rb`
Expected: FAIL — `last_interactive` is `nil` (processor never passes `interactive:`).

- [ ] **Step 3: Pass `interactive` from `process` into `chat`**

In `lib/ezclaw/message_processor.rb`, change the `process` signature + add the derivation. Replace lines 19-21:

```ruby
    def process(user_message:, conversation_history: [], source: "unknown", on_status: nil)
      messages = build_messages(user_message, conversation_history)
      tools = @registry.schemas
```

with:

```ruby
    def process(user_message:, conversation_history: [], source: "unknown", on_status: nil)
      messages = build_messages(user_message, conversation_history)
      tools = @registry.schemas
      # Cron/heartbeat work is unattended: let the LLM client retry hard.
      # Everything else is interactive and should fail fast.
      interactive = !source.to_s.start_with?("cron:")
```

Then replace the chat call (line 29):

```ruby
        response = @llm.chat(messages: messages, tools: tools)
```

with:

```ruby
        response = @llm.chat(messages: messages, tools: tools, interactive: interactive)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/test_message_processor.rb`
Expected: PASS (existing 4 tests + 2 new).

- [ ] **Step 5: Commit**

```bash
git add lib/ezclaw/message_processor.rb test/ezclaw/test_message_processor.rb
git commit -m "feat(processor): cron sources use unattended LLM retry policy"
```

---

### Task 5: `Scheduler` posts a Slack alert when a trigger fails

**Files:**
- Modify: `lib/ezclaw/scheduler.rb:7-12` (constructor) and `:36-49` (`handle_trigger`)
- Test: `test/ezclaw/test_scheduler.rb` (create)

- [ ] **Step 1: Write the failing test**

Create `test/ezclaw/test_scheduler.rb`:

```ruby
# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestScheduler < Minitest::Test
  # Processor double whose behavior is set per-test.
  class FakeProcessor
    def initialize(&blk) = (@blk = blk)
    def process(**) = @blk.call
  end

  def setup
    @logger = Ezclaw::Log.new(output: StringIO.new, level: :debug)
    @config = Ezclaw::Config.new(
      { "slack" => { "channels" => [{ "id" => "C0BDXPJ9E3E", "name" => "coach" }] } },
      "/tmp"
    )
    @posted = []
    fake_client = Object.new
    posted = @posted
    fake_client.define_singleton_method(:chat_postMessage) { |**kw| posted << kw }
    Ezclaw::Tools::SlackPostTool.slack_client = fake_client
  end

  def teardown
    Ezclaw::Tools::SlackPostTool.slack_client = nil
  end

  def test_posts_alert_to_home_channel_on_failure
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529: overloaded", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")

    assert_equal 1, @posted.length
    assert_equal "C0BDXPJ9E3E", @posted[0][:channel]
    assert_match(/heartbeat/, @posted[0][:text])
    assert_match(/529/, @posted[0][:text])
  end

  def test_no_alert_on_success
    processor = FakeProcessor.new { { role: "assistant", content: "ok" } }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")

    assert_empty @posted
  end

  def test_failure_without_slack_client_does_not_raise
    Ezclaw::Tools::SlackPostTool.slack_client = nil
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger, config: @config)

    sched.trigger_now("heartbeat")  # must not raise
    assert_empty @posted
  end

  def test_failure_without_config_does_not_raise
    processor = FakeProcessor.new { raise Ezclaw::LLM::APIError.new("HTTP 529", status: 529) }
    sched = Ezclaw::Scheduler.new(processor: processor, schedule: {}, logger: @logger)

    sched.trigger_now("heartbeat")  # config: nil -> no channel -> no post, no raise
    assert_empty @posted
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/test_scheduler.rb`
Expected: FAIL — `Scheduler.new` doesn't accept `config:`; no alert posted.

- [ ] **Step 3: Add `config:` to the constructor**

In `lib/ezclaw/scheduler.rb`, replace the constructor (lines 7-12):

```ruby
    def initialize(processor:, schedule:, logger:)
      @processor = processor
      @schedule = schedule || {}
      @logger = logger
      @scheduler = Rufus::Scheduler.new
    end
```

with:

```ruby
    def initialize(processor:, schedule:, logger:, config: nil)
      @processor = processor
      @schedule = schedule || {}
      @logger = logger
      @config = config
      @scheduler = Rufus::Scheduler.new
    end
```

- [ ] **Step 4: Post the alert from the rescue block**

In `lib/ezclaw/scheduler.rb`, replace `handle_trigger` and add helpers (lines 36-49):

```ruby
    def handle_trigger(name)
      @logger.info("cron", "Triggered: #{name}")

      time_str = Time.now.strftime("%A %B %d, %Y %I:%M %p %Z")
      message = "Heartbeat triggered: #{name}. Current time: #{time_str}. " \
                "Check your heartbeat instructions and execute the appropriate tasks for this trigger."

      begin
        result = @processor.process(user_message: message, source: "cron:#{name}")
        @logger.info("cron", "Completed: #{name} — #{result[:content]&.slice(0, 100)}")
      rescue => e
        @logger.error("cron", "Failed: #{name} — #{e.class}: #{e.message}")
      end
    end
```

with:

```ruby
    def handle_trigger(name)
      @logger.info("cron", "Triggered: #{name}")

      time_str = Time.now.strftime("%A %B %d, %Y %I:%M %p %Z")
      message = "Heartbeat triggered: #{name}. Current time: #{time_str}. " \
                "Check your heartbeat instructions and execute the appropriate tasks for this trigger."

      begin
        result = @processor.process(user_message: message, source: "cron:#{name}")
        @logger.info("cron", "Completed: #{name} — #{result[:content]&.slice(0, 100)}")
      rescue => e
        @logger.error("cron", "Failed: #{name} — #{e.class}: #{e.message}")
        notify_failure(name, e)
      end
    end

    # Post a Slack alert so a missed heartbeat (e.g. LLM overloaded after all
    # retries) is visible instead of dying silently in the logs. Must never
    # raise out of the rescue block above.
    def notify_failure(name, error)
      channel = alert_channel
      return unless channel

      client = Tools::SlackPostTool.slack_client
      return unless client

      text = ":warning: Heartbeat `#{name}` failed after multiple retries. " \
             "No brief was posted.\nLast error: `#{error.message.to_s.slice(0, 300)}`"
      client.chat_postMessage(channel: channel, text: text)
    rescue => e
      @logger.error("cron", "Failed to post failure alert for #{name}: #{e.class}: #{e.message}")
    end

    def alert_channel
      return nil unless @config

      channels = @config.slack["channels"] || []
      first = channels.first
      first && first["id"]
    end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/test_scheduler.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/ezclaw/scheduler.rb test/ezclaw/test_scheduler.rb
git commit -m "feat(scheduler): post Slack alert when a heartbeat fails after retries"
```

---

### Task 6: `Bot` passes config to the scheduler

**Files:**
- Modify: `lib/ezclaw/bot.rb:111` (`run_dry`) and `lib/ezclaw/bot.rb:140` (`run_production`)
- Test: covered by `test/ezclaw/test_bot.rb` (structural — must stay green)

- [ ] **Step 1: Update both `Scheduler.new` call sites**

In `lib/ezclaw/bot.rb`, replace line 111:

```ruby
      scheduler = Scheduler.new(processor: @processor, schedule: @config.schedule, logger: @logger)
```

with:

```ruby
      scheduler = Scheduler.new(processor: @processor, schedule: @config.schedule, logger: @logger, config: @config)
```

There are two identical lines (in `run_dry` and `run_production`). Update BOTH occurrences to add `, config: @config`.

- [ ] **Step 2: Verify the bot structural test still passes**

Run: `mise exec -- ruby -Itest -Ilib test/ezclaw/test_bot.rb`
Expected: PASS (2 runs, 0 failures) — the trap-handler regex checks are unaffected.

- [ ] **Step 3: Commit**

```bash
git add lib/ezclaw/bot.rb
git commit -m "feat(bot): pass config to scheduler for failure alerts"
```

---

### Task 7: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run:
```bash
mise exec -- ruby -Itest -Ilib -e 'Dir.glob("test/**/test_*.rb").each { |f| require File.expand_path(f) }'
```
Expected: All tests pass, 0 failures, 0 errors. Pay special attention that `test/ezclaw/llm/test_openrouter.rb` `test_raises_after_max_retries` (uses `.times(3)`) still passes — the interactive schedule `[0.2, 0.4]` yields exactly 3 attempts.

- [ ] **Step 2: Confirm no stale references to removed `MAX_RETRIES`**

Run: `grep -rn "MAX_RETRIES" lib/ test/`
Expected: no output (constant fully removed).

- [ ] **Step 3: Final commit (if grep or suite surfaced fixes; otherwise skip)**

```bash
git add -A
git commit -m "test: full-suite verification for retry backoff + heartbeat alert"
```

---

## Notes for the implementer

- **Deployment (out of plan scope):** these changes take effect only after the `ghcr.io/gammons/ezclaw` image is rebuilt/published and coach is redeployed. No coach-repo change is required. Do NOT run any cluster commands as part of this plan.
- **Why two sleep seams (`jitter`, `sleep_for`):** they let unit tests assert the exact backoff schedule deterministically and without real waiting. Production code paths use the real `sleep` and real jitter.
- **Alert wording deliberately omits an exact attempt count** — the scheduler doesn't know how many retries the LLM layer made, and plumbing that up isn't worth the coupling. The raw error message (truncated to 300 chars) carries the HTTP status for diagnosis.
