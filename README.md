# Ezclaw

A simple Ruby bot framework for running LLM-powered agents with Slack integration and cron scheduling. Built as a lightweight alternative to OpenClaw — easier to understand, debug, and deploy.

## What it does

Ezclaw runs a single bot per process. Each bot:

- Connects to Slack via Socket Mode and responds to messages
- Runs scheduled tasks (heartbeats, reports) via internal cron
- Uses LLM tool calling to execute actions (fetch URLs, run shell commands, post to Slack, etc.)
- Maintains persistent memory across sessions via a simple markdown file

## Quick start

### Prerequisites

- Ruby 4.0+
- An OpenRouter or Anthropic API key
- A Slack app with Socket Mode enabled (optional, for Slack integration)

### Install

```bash
git clone <repo-url> && cd ezclaw
bundle install
```

### Configure

Create a `.env` file:

```
OPENROUTER_API_KEY=sk-or-...
SLACK_BOT_TOKEN=xoxb-...      # optional
SLACK_APP_TOKEN=xapp-...      # optional
```

### Run

```bash
# Interactive REPL (no Slack, no cron — for testing)
ruby ezclaw.rb --bot bots/pulse --repl

# Production (Slack + cron)
ruby ezclaw.rb --bot bots/pulse

# Dry run (trigger each schedule once, print output, exit)
ruby ezclaw.rb --bot bots/pulse --dry
```

## Creating a bot

A bot is a directory:

```
bots/mybot/
  config.yaml      # LLM, Slack, schedule, context config
  role.md           # Persona / system prompt
  memory.md         # Long-term memory (writable at runtime)
  heartbeat.md      # Instructions for scheduled tasks
  tools/            # Ruby files defining custom tools
    my_tool.rb
```

### config.yaml

```yaml
name: mybot

slack:
  channels:
    - id: C12345678
      name: general
      require_mention: true
  dm_policy: open

llm:
  provider: openrouter           # "openrouter", "anthropic", or "custom"
  model: anthropic/claude-sonnet-4
  max_tokens: 8192
  # For custom providers:
  # base_url: https://api.example.com/v1/chat/completions
  # format: openai               # "openai" or "anthropic"
  # api_key_env: MY_API_KEY

schedule:
  heartbeat: "*/10 * * * *"     # every 10 minutes
  weekly_report: "0 9 * * 1"   # Monday 9 AM

context:
  system_files:
    - role.md
    - heartbeat.md
  memory_file: memory.md

logging:
  level: info                    # debug, info, warn, error
```

### Custom tools

Tools are Ruby classes in the `tools/` directory:

```ruby
class StripeTool < Ezclaw::Tool
  desc "Check Stripe MRR and subscription metrics"
  param :metric, type: :string, enum: %w[mrr churn subscriptions], required: true

  def call(metric:)
    # Your code here — make API calls, process data, etc.
    # Return value is sent back to the LLM as the tool result
  end
end
```

Tools are auto-discovered from the `tools/` directory. Any class inheriting from `Ezclaw::Tool` is registered automatically.

## Built-in tools

Every bot gets these tools automatically:

| Tool | Description |
|------|-------------|
| `update_memory` | Update the bot's persistent memory.md file |
| `slack_post` | Post a message to a Slack channel |
| `web_fetch` | Fetch a URL (GET/POST, follows redirects, custom headers) |
| `shell_exec` | Execute a shell command (with timeout and output capture) |

## How it works

```
+----------------------------------------------+
|              Ezclaw Process               |
|                                              |
|  +-------------+     +------------------+    |
|  | Slack Socket |---->|                  |    |
|  |  Mode        |     |   Message        |    |
|  +-------------+     |   Processor      |    |
|                       |                  |    |
|  +-------------+     |  1. Build prompt  |    |
|  | Cron        |---->|  2. Call LLM      |--->|--> LLM API
|  | Scheduler   |     |  3. Execute tools |    |
|  +-------------+     |  4. Respond       |    |
|                       +------------------+    |
|  +-------------+                              |
|  | Debug REPL  |-------- (same pipeline) ---->|
|  +-------------+                              |
+----------------------------------------------+
```

Three input sources feed the same message processor:

- **Slack** — messages and mentions via Socket Mode
- **Cron** — scheduled heartbeat tasks via rufus-scheduler
- **REPL** — interactive debug chat (local only)

Each invocation builds a system prompt from the bot's persona files + memory, sends it to the LLM with available tools, executes any tool calls in a loop, and returns the response.

### Context model

- **System prompt**: concatenation of files listed in `context.system_files` + `memory_file`
- **Conversation history**: for Slack, the thread history is fetched automatically; for REPL, history is maintained in-session
- **No session management**: each invocation is independent. Slack threads are the sessions.

### Memory

The bot can update its own memory via the `update_memory` tool. Memory is stored as a markdown file on disk (PVC in Kubernetes). You can read it anytime to see exactly what the bot "knows."

## Kubernetes deployment

### Docker

```bash
docker build -t ezclaw .
```

The image is generic — bot config is injected via ConfigMaps.

### Helm

```bash
helm install pulse ./helm/ezclaw -f my-pulse-values.yaml
```

The chart generates a ConfigMap (bot config + files), a PVC (writable state), and a single-replica Deployment. See `helm/ezclaw/values.yaml` for the full schema.

Example values for deploying a bot:

```yaml
image:
  repository: ghcr.io/youruser/ezclaw
  tag: latest

bot:
  name: pulse
  config: |
    name: pulse
    llm:
      provider: openrouter
      model: anthropic/claude-sonnet-4
    schedule:
      heartbeat: "*/10 * * * *"
    context:
      system_files: [role.md, heartbeat.md]
      memory_file: memory.md

  files:
    role.md: |
      # Pulse - Data Analyst
      You are Pulse, a data analyst bot...
    heartbeat.md: |
      # Heartbeat Tasks
      ...
    memory.md: |
      # Memory
      ...

secrets:
  existingSecret: ezclaw-pulse-env  # contains API keys

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { cpu: 500m, memory: 256Mi }

persistence:
  size: 1Gi
```

### Bots that need extra system tools

Some bots need binaries that aren't in the base image. For example, an SRE bot needs `kubectl`. The Helm chart supports this via init containers, extra volumes, and extra environment variables.

Here's how to deploy a bot with kubectl access:

```yaml
image:
  repository: ghcr.io/youruser/ezclaw
  tag: latest

bot:
  name: grid
  config: |
    name: grid
    llm:
      provider: openrouter
      model: anthropic/claude-sonnet-4
    schedule:
      heartbeat: "*/10 * * * *"
    context:
      system_files: [role.md, heartbeat.md]
      memory_file: memory.md
  files:
    role.md: |
      # Grid - SRE Bot
      You are Grid, an SRE and infrastructure watchdog...
    heartbeat.md: |
      # Heartbeat Tasks
      ...
    memory.md: |
      # Memory
      ...

secrets:
  existingSecret: ezclaw-grid-env

resources:
  requests: { cpu: 400m, memory: 768Mi }
  limits: { cpu: 3000m, memory: 4Gi }

persistence:
  size: 5Gi

# ServiceAccount for RBAC (kubectl needs cluster permissions)
serviceAccount:
  create: true

# Make kubectl available on PATH and point to kubeconfig
extraEnv:
  - name: KUBECONFIG
    value: /home/ezclaw/.kube/config
  - name: PATH
    value: /tools:/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Mount kubeconfig from a secret + shared tools directory
extraVolumeMounts:
  - name: kubeconfig
    mountPath: /home/ezclaw/.kube
    readOnly: true
  - name: tools
    mountPath: /tools

extraVolumes:
  - name: kubeconfig
    secret:
      secretName: grid-kubeconfig
  - name: tools
    emptyDir: {}

# Download kubectl at pod startup
initContainers:
  - name: install-kubectl
    image: ghcr.io/youruser/ezclaw:latest
    command:
      - sh
      - -c
      - |
        ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
        curl -LsSo /tools/kubectl \
          "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
        chmod +x /tools/kubectl
    volumeMounts:
      - name: tools
        mountPath: /tools
```

How it works:

1. The **init container** downloads `kubectl` to an `emptyDir` volume at `/tools`
2. The **`PATH` env var** includes `/tools`, so the bot's `shell_exec` tool can find `kubectl`
3. The **kubeconfig** is mounted from a Kubernetes Secret
4. The **ServiceAccount** is created so you can bind RBAC roles to it (create a `ClusterRoleBinding` separately)

This same pattern works for any binary — `gh` (GitHub CLI), `aws`, `helm`, `psql`, etc. Just add more downloads to the init container.

## LLM providers

| Provider | Config | Env var |
|----------|--------|---------|
| OpenRouter | `provider: openrouter` | `OPENROUTER_API_KEY` |
| Anthropic | `provider: anthropic` | `ANTHROPIC_API_KEY` |
| Custom | `provider: custom`, `base_url: ...`, `format: openai\|anthropic` | configurable via `api_key_env` |

## Slack app setup

Your Slack app needs:

- **Socket Mode** enabled
- **Bot Token Scopes**: `app_mentions:read`, `channels:history`, `channels:read`, `chat:write`, `groups:history`, `groups:read`, `im:history`, `im:read`, `im:write`, `reactions:read`, `reactions:write`, `assistant:write`
- **Event Subscriptions** (bot events): `app_mention`, `message.channels`, `message.groups`, `message.im`
- **App-Level Token** with `connections:write` scope

## Project structure

```
ezclaw.rb              # CLI entry point
lib/
  ezclaw.rb            # Module root
  ezclaw/
    bot.rb                # Wires all components together
    config.rb             # Loads bot config directory
    logger.rb             # Structured logging
    memory.rb             # Read/write memory files
    message_processor.rb  # Core: prompt building, LLM loop, tool dispatch
    repl.rb               # Debug REPL
    scheduler.rb          # Cron scheduling via rufus-scheduler
    slack_listener.rb     # Slack Socket Mode via faye-websocket
    tool.rb               # Tool base class with DSL
    tool_registry.rb      # Tool loading and execution
    llm/
      base.rb             # LLM adapter interface + retry logic
      openrouter.rb       # OpenRouter (OpenAI-compatible)
      anthropic.rb        # Anthropic native API
      custom.rb           # Custom endpoint with format selection
    tools/
      update_memory.rb    # Built-in: update memory file
      slack_post.rb       # Built-in: post to Slack
      web_fetch.rb        # Built-in: HTTP requests
      shell_exec.rb       # Built-in: shell command execution
helm/ezclaw/           # Minimal Helm chart
bots/pulse/               # Example bot configuration
test/                     # Minitest test suite
```

## Running tests

```bash
bundle exec ruby -Itest -e "Dir.glob('test/**/test_*.rb').each { |f| require File.expand_path(f) }"
```
