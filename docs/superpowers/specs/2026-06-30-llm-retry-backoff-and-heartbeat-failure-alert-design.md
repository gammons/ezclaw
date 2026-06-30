# LLM Retry Backoff + Heartbeat Failure Alert — Design

**Date:** 2026-06-30
**Status:** Approved, ready for implementation plan

## Problem

On 2026-06-30 coach's morning brief (cron `heartbeat`) failed. The data-gathering
LLM call succeeded, but the final compose call returned `HTTP 529 overloaded_error`
from z.ai. The brief was never posted and there was no notification — the failure
was only visible in pod logs.

Root cause is twofold:

1. **Backoff too short.** `Ezclaw::LLM::Base#with_retries` already retries on
   `APIError` (`MAX_RETRIES = 3`), but the backoff is `0.1 * 2**attempts` → ~0.2s
   then ~0.4s, ~0.6s total. A transient upstream overload needs seconds-to-minutes
   to clear, so all three attempts hit the same outage window and the brief is lost
   for the whole day.
2. **Silent failure.** `Scheduler#handle_trigger` rescues the exception and only
   logs it. The user has no idea the brief didn't go out.

## Constraints / Key Insight

The retry path in `Base#with_retries` is shared by **both** interactive Slack
replies and unattended cron heartbeats (both go through
`MessageProcessor#process` → `@llm.chat`). These have opposite requirements:

- **Interactive:** fail fast. A human is waiting; better to error in ~1s so they
  can retry by typing than to hang for a minute.
- **Cron / heartbeat:** wait it out. Nobody is waiting; spending up to ~2 minutes
  riding out an overload is free and maximizes the chance the brief is delivered.

So backoff aggressiveness must be **context-dependent**, not global.

## Design

### 1. Context-aware backoff in the LLM layer

Add a notion of retry "context" so `chat` (and therefore `with_retries`) knows
whether it is serving an interactive request or an unattended one.

- **Interactive (default):** keep current fast-fail behavior — ~2 quick attempts,
  sub-second backoff. Replies fail fast during an outage.
- **Unattended (cron/heartbeat):** aggressive schedule
  **5s → 15s → 30s → 60s**, i.e. 5 total attempts, ~110s max cumulative wait.
  Each sleep gets **jitter** (e.g. ±20%) to avoid synchronized retries across bots.

Only **transient** errors are retried in either mode. Right now `APIError` is
raised for *any* non-200, so a 400 bad-request is pointlessly retried. Scope
retries to transient status codes (**429 and 5xx**); fail fast on other 4xx.

The context flag threads from the caller (`MessageProcessor#process`, which knows
its `source:` — e.g. `cron:heartbeat` vs `slack`) down into `chat` and into
`with_retries`. Exact mechanism (parameter vs. lightweight retry-policy object) to
be decided in the implementation plan; the behavior above is the contract.

### 2. Heartbeat failure alert in the Scheduler

When `Scheduler#handle_trigger` exhausts retries and the exception propagates, it
currently only logs. Add: post a Slack alert to the bot's home channel.

- **Channel:** first channel from `@config.slack.channels` (generic across bots;
  coach → `#coach` / `C0BDXPJ9E3E`). Requires giving the scheduler access to the
  bot config (it currently only receives `schedule:`).
- **Client:** reuse the already-wired `Tools::SlackPostTool.slack_client`
  (set in `bot.rb` production startup). No new Slack handle needed.
- **Message (includes raw error for fast diagnosis):**

  > ⚠️ Heartbeat `heartbeat` failed after 5 attempts. LLM error:
  > `HTTP 529: overloaded_error`. No brief was posted.

- The alert post itself must be defensive: if Slack posting fails or no client is
  configured (e.g. dry-run/REPL), fall back to logging only — never raise out of
  the rescue block.

## Out of Scope

- No change to the cron schedule / timing.
- No change to coach's bot files (this is a pure ezclaw framework change).
- No persistent retry/dead-letter queue — a missed heartbeat is surfaced via the
  Slack alert; the next day's run is the recovery.

## Affected Files

- `lib/ezclaw/llm/base.rb` — context-aware backoff schedule, transient-only retry,
  jitter.
- `lib/ezclaw/llm/anthropic.rb`, `lib/ezclaw/llm/openrouter.rb` — pass retry
  context / classify transient vs. permanent errors at the `raise` site.
- `lib/ezclaw/message_processor.rb` — thread context (derived from `source:`) into
  `chat`.
- `lib/ezclaw/scheduler.rb` — accept bot config; post Slack alert on exhausted
  heartbeat failure.
- `lib/ezclaw/bot.rb` — pass config to `Scheduler.new`.
- Tests under `test/` for: transient-retry-then-success, permanent-error-no-retry,
  interactive-vs-cron backoff selection, and scheduler-posts-alert-on-failure.

## Deployment Note

Takes effect only after the ezclaw image is rebuilt/published and coach is
redeployed. No coach-repo change required.
