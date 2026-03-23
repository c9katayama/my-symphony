# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## Claude Code backend

By default Symphony uses Codex. To use [Claude Code CLI](https://github.com/anthropics/claude-code)
instead, set `agent.backend` to `claude_code` in your `WORKFLOW.md`:

```yaml
agent:
  backend: claude_code

claude_code:
  command: claude          # path to the claude binary (default: "claude")
  model: claude-sonnet-4-6 # optional — omit to use the CLI default
  turn_timeout_ms: 3600000 # optional, default 1 hour
  stall_timeout_ms: 300000 # optional, default 5 minutes
```

Claude Code runs with `--dangerously-skip-permissions` so no human approval is required during
agent turns. Authentication uses Claude Code's own credentials — run `claude auth` beforehand, or
set `ANTHROPIC_API_KEY` if you prefer API key authentication.

> [!NOTE]
> Claude Code backend does not support `worker.ssh_hosts`. Use it for local workers only.

---

## Slack integration

Symphony can send progress notifications to Slack and accept commands via
[Socket Mode](https://api.slack.com/apis/socket-mode) (no public endpoint required).

### Setup

**1. Create a Slack App**

Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app **from scratch**.

**2. Enable Socket Mode**

Navigate to **Socket Mode** and enable it. Create an **App-Level Token** with the
`connections:write` scope. This is your `app_token` (`xapp-…`).

**3. Add Bot Token Scopes**

Under **OAuth & Permissions → Bot Token Scopes**, add:

- `chat:write` — post messages
- `channels:history` — read thread messages for summarization

**4. Subscribe to Events**

Under **Event Subscriptions**, enable events and subscribe to `message.channels`.

**5. Install the App**

Install the app to your workspace and copy the **Bot User OAuth Token** (`xoxb-…`). This is your
`bot_token`.

**6. Configure WORKFLOW.md**

```yaml
slack:
  enabled: true
  app_token: $SLACK_APP_TOKEN          # xapp-… token (Socket Mode)
  bot_token: $SLACK_BOT_TOKEN          # xoxb-… token
  notification_channel: "C1234567890"  # channel ID for Linear-originated notifications
  summarization_model: claude-sonnet-4-6  # optional, used to summarize threads
```

Set the environment variables `SLACK_APP_TOKEN` and `SLACK_BOT_TOKEN`, or write the values
directly. Set `ANTHROPIC_API_KEY` to enable thread summarization (used when creating issues from
Slack threads via `/implement`).

### Slack commands

Mention the bot in any channel to issue commands:

| Command | Effect |
|---|---|
| `@bot /work SYM-123` | Move issue to **Todo** (Orchestrator picks it up) |
| `@bot /pause SYM-123` | Move issue to **Backlog** |
| `@bot /retry SYM-123` | Move issue back to **Todo** |
| `@bot /status` | Show current orchestrator state |
| `@bot /implement <description>` | Create a new Linear issue from text |
| `@bot /implement` (in a thread) | Create a Linear issue from the thread summary |

### Notifications

- Issues created via Linear are tracked in `notification_channel`. The first notification starts
  a thread; subsequent updates reply in that thread.
- Issues created from Slack are tracked in the originating Slack thread.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
