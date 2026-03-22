# Claude Code + Slack Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Claude Code CLI as an alternative agent backend to Symphony, and add bidirectional Slack integration via Socket Mode.

**Architecture:** Layered extension — AgentAdapter behaviour abstracts Codex/Claude Code, Slack.Supervisor manages Socket Mode connection and notifications. Linear remains source of truth. Orchestrator changes are minimal (adapter dispatch + notification hooks).

**Tech Stack:** Elixir/OTP, Port (Claude Code CLI), fresh (WebSocket for Slack Socket Mode), req (HTTP for Slack API + Anthropic API)

**Spec:** `docs/superpowers/specs/2026-03-22-claude-code-slack-integration-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `lib/symphony_elixir/agent_adapter.ex` | Behaviour definition for agent backends |
| `lib/symphony_elixir/codex/adapter.ex` | Codex adapter wrapping existing AppServer |
| `lib/symphony_elixir/claude_code/adapter.ex` | Claude Code CLI adapter using Port |
| `lib/symphony_elixir/claude_code/output_parser.ex` | Parse Claude Code JSON output + streaming lines |
| `lib/symphony_elixir/slack/supervisor.ex` | Slack subsystem supervisor (:rest_for_one) |
| `lib/symphony_elixir/slack/socket.ex` | Socket Mode WebSocket GenServer |
| `lib/symphony_elixir/slack/api.ex` | Slack Web API client (chat.postMessage, conversations.replies, etc.) |
| `lib/symphony_elixir/slack/event_handler.ex` | Event routing (mention detection, thread context) |
| `lib/symphony_elixir/slack/thread_context.ex` | Thread fetching + Anthropic API summarization |
| `lib/symphony_elixir/slack/notifier.ex` | Notification GenServer (thread mapping, rate limiting) |
| `lib/symphony_elixir/slack/commands.ex` | Command parsing from Slack messages |
| `lib/symphony_elixir/slack/linear_actions.ex` | Linear API mutations triggered from Slack commands |
| `test/symphony_elixir/agent_adapter_test.exs` | Adapter behaviour tests |
| `test/symphony_elixir/claude_code/adapter_test.exs` | Claude Code adapter tests |
| `test/symphony_elixir/claude_code/output_parser_test.exs` | Output parser tests |
| `test/symphony_elixir/slack/event_handler_test.exs` | Event handler tests |
| `test/symphony_elixir/slack/thread_context_test.exs` | Thread context tests |
| `test/symphony_elixir/slack/commands_test.exs` | Command parser tests |
| `test/symphony_elixir/slack/notifier_test.exs` | Notifier tests |
| `test/symphony_elixir/slack/socket_test.exs` | Socket event dispatch tests |
| `test/symphony_elixir/slack/linear_actions_test.exs` | Linear action tests |

### Modified Files
| File | Changes |
|------|---------|
| `lib/symphony_elixir/config/schema.ex` | Add `backend` to Agent, new ClaudeCode + Slack embedded schemas |
| `lib/symphony_elixir/agent_runner.ex` | Replace direct AppServer calls with AgentAdapter dispatch |
| `lib/symphony_elixir.ex` | Add Slack.Supervisor to supervision tree |
| `lib/symphony_elixir/orchestrator.ex` | Add notification hooks on state change + turn complete |
| `mix.exs` | Add `fresh` dependency |

---

## Key Design Decisions

### AgentAdapter return value convention

Both adapters return `{:ok, result_map}` from `run_turn/4` — matching the existing `AppServer.run_turn/4` contract. The Claude Code adapter manages `session_id` internally (stored in adapter state) and exposes it via `result_map[:session_id]` for the AgentRunner to update the Orchestrator's running entry. The adapter state is passed by reference through a process — not returned as a 3rd tuple element.

To achieve this, the Claude Code adapter uses an `Agent` process (started in `start_session`) to hold mutable session state (session_id). The `run_turn` reads and updates this state internally.

### finalize_settings cross-validation

The existing `finalize_settings/1` returns a bare struct. Cross-field validation (claude_code + ssh_hosts exclusion) is added in `parse/1` **after** `finalize_settings`, so the return type is preserved.

### Embedded schema defaults

All new `embeds_one` declarations use `on_replace: :update, defaults_to_struct: true` to match the existing pattern, ensuring `settings.slack` and `settings.claude_code` are always structs (never nil).

### continue_with_issue? preservation

The existing `continue_with_issue?/2` returns `{:continue, refreshed_issue}`, `{:done, _}`, or `{:error, _}`. The refactored AgentRunner preserves this exact pattern and passes the refreshed issue to the next turn.

---

## Task 1: Config Schema — Add `backend` field and ClaudeCode schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:122-200, 264-289`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Write failing test for `backend` field in Agent schema**

```elixir
# In test/symphony_elixir/core_test.exs, add to the config tests section:

test "agent.backend defaults to codex" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"}
  })

  settings = Config.settings!()
  assert settings.agent.backend == "codex"
end

test "agent.backend accepts claude_code" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "agent" => %{"backend" => "claude_code"}
  })

  settings = Config.settings!()
  assert settings.agent.backend == "claude_code"
end

test "agent.backend rejects invalid values" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "agent" => %{"backend" => "invalid"}
  })

  assert {:error, _} = Config.settings()
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: FAIL — `backend` field does not exist

- [ ] **Step 3: Add `backend` field to Agent schema**

In `lib/symphony_elixir/config/schema.ex`, inside `defmodule Agent` embedded_schema block (around line 130):

```elixir
field :backend, :string, default: "codex"
```

Add validation in the Agent changeset function:

```elixir
|> cast(params, [...existing fields..., :backend])
|> validate_inclusion(:backend, ["codex", "claude_code"])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Write failing test for ClaudeCode config schema**

```elixir
test "claude_code config with defaults" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "agent" => %{"backend" => "claude_code"}
  })

  settings = Config.settings!()
  assert settings.claude_code.command == "claude"
  assert settings.claude_code.turn_timeout_ms == 3_600_000
  assert settings.claude_code.stall_timeout_ms == 300_000
  assert settings.claude_code.additional_flags == []
end

test "claude_code config with custom values" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "agent" => %{"backend" => "claude_code"},
    "claude_code" => %{
      "command" => "/usr/local/bin/claude",
      "model" => "opus",
      "additional_flags" => ["--verbose"],
      "turn_timeout_ms" => 600_000
    }
  })

  settings = Config.settings!()
  assert settings.claude_code.command == "/usr/local/bin/claude"
  assert settings.claude_code.model == "opus"
  assert settings.claude_code.additional_flags == ["--verbose"]
  assert settings.claude_code.turn_timeout_ms == 600_000
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: FAIL — `claude_code` field does not exist on settings

- [ ] **Step 7: Add ClaudeCode embedded schema**

In `lib/symphony_elixir/config/schema.ex`, after the Codex module (around line 200):

```elixir
defmodule ClaudeCode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :command, :string, default: "claude"
    field :model, :string
    field :additional_flags, {:array, :string}, default: []
    field :turn_timeout_ms, :integer, default: 3_600_000
    field :stall_timeout_ms, :integer, default: 300_000
  end

  def changeset(schema \\ %__MODULE__{}, params) do
    schema
    |> cast(params, [:command, :model, :additional_flags, :turn_timeout_ms, :stall_timeout_ms])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than: 0)
  end
end
```

Add to the top-level embedded_schema (around line 268):

```elixir
embeds_one(:claude_code, ClaudeCode, on_replace: :update, defaults_to_struct: true)
```

Add to the top-level changeset (follow existing pattern):

```elixir
|> cast_embed(:claude_code)
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 9: Write failing test for claude_code + ssh_hosts validation**

```elixir
test "claude_code backend rejects ssh_hosts" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "agent" => %{"backend" => "claude_code"},
    "worker" => %{"ssh_hosts" => ["user@host:22"]}
  })

  assert {:error, _} = Config.settings()
end
```

- [ ] **Step 10: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: FAIL — validation does not exist yet

- [ ] **Step 11: Add cross-field validation in parse/1 (after finalize_settings)**

In `lib/symphony_elixir/config/schema.ex`, modify `parse/1` (around line 277-289):

```elixir
def parse(config) when is_map(config) do
  config
  |> normalize_keys()
  |> drop_nil_values()
  |> changeset()
  |> apply_action(:validate)
  |> case do
    {:ok, settings} ->
      settings = finalize_settings(settings)
      validate_backend_worker_compatibility(settings)

    {:error, changeset} ->
      {:error, {:invalid_workflow_config, format_errors(changeset)}}
  end
end

defp validate_backend_worker_compatibility(settings) do
  if settings.agent.backend == "claude_code" and
       settings.worker.ssh_hosts != [] do
    {:error, {:invalid_workflow_config, "claude_code backend does not support ssh_hosts"}}
  else
    {:ok, settings}
  end
end
```

Note: `settings.worker` is always a struct (never nil) because of `defaults_to_struct: true`.

- [ ] **Step 12: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 13: Commit**

```bash
cd elixir && git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/core_test.exs
git commit -m "feat: add agent.backend and claude_code config schema

Add backend field to Agent schema (codex|claude_code).
Add ClaudeCode embedded schema with command, model, additional_flags, timeouts.
Validate claude_code + ssh_hosts mutual exclusion in parse/1."
```

---

## Task 2: AgentAdapter Behaviour

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_adapter.ex`
- Create: `elixir/test/symphony_elixir/agent_adapter_test.exs`

- [ ] **Step 1: Write the behaviour module**

The behaviour matches the existing `AppServer` contract: `run_turn/4` returns `{:ok, result_map}` (2-tuple).

```elixir
# lib/symphony_elixir/agent_adapter.ex
defmodule SymphonyElixir.AgentAdapter do
  @moduledoc """
  Behaviour for agent backends (Codex, Claude Code).

  All adapters must return {:ok, result_map} from run_turn/4,
  matching the existing AppServer.run_turn/4 contract.
  Session state is managed internally by the adapter.
  """

  @type session :: term()

  @callback start_session(workspace :: String.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, result :: map()} | {:error, term()}

  @callback stop_session(session()) :: :ok

  @spec adapter_for(String.t()) :: module()
  def adapter_for("codex"), do: SymphonyElixir.Codex.Adapter
  def adapter_for("claude_code"), do: SymphonyElixir.ClaudeCode.Adapter
end
```

- [ ] **Step 2: Write test for adapter_for/1**

```elixir
# test/symphony_elixir/agent_adapter_test.exs
defmodule SymphonyElixir.AgentAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentAdapter

  test "adapter_for returns Codex adapter" do
    assert AgentAdapter.adapter_for("codex") == SymphonyElixir.Codex.Adapter
  end

  test "adapter_for returns Claude Code adapter" do
    assert AgentAdapter.adapter_for("claude_code") == SymphonyElixir.ClaudeCode.Adapter
  end

  test "adapter_for raises on unknown backend" do
    assert_raise FunctionClauseError, fn ->
      AgentAdapter.adapter_for("unknown")
    end
  end
end
```

- [ ] **Step 3: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/agent_adapter_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent_adapter.ex test/symphony_elixir/agent_adapter_test.exs
git commit -m "feat: add AgentAdapter behaviour definition"
```

---

## Task 3: Codex Adapter (wrap existing AppServer)

**Files:**
- Create: `elixir/lib/symphony_elixir/codex/adapter.ex`

- [ ] **Step 1: Implement Codex adapter — thin wrapper, delegates directly**

```elixir
# lib/symphony_elixir/codex/adapter.ex
defmodule SymphonyElixir.Codex.Adapter do
  @moduledoc "AgentAdapter implementation wrapping Codex.AppServer."
  @behaviour SymphonyElixir.AgentAdapter

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts \\ []) do
    AppServer.start_session(workspace, opts)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
```

- [ ] **Step 2: Verify compilation + run existing AppServer tests**

Run: `cd elixir && mix compile --warnings-as-errors 2>&1 | tail -5 && mix test test/symphony_elixir/app_server_test.exs --seed 0 2>&1 | tail -10`
Expected: Compiled + existing tests pass

- [ ] **Step 3: Commit**

```bash
cd elixir && git add lib/symphony_elixir/codex/adapter.ex
git commit -m "feat: add Codex.Adapter wrapping existing AppServer"
```

---

## Task 4: Claude Code Output Parser

**Files:**
- Create: `elixir/lib/symphony_elixir/claude_code/output_parser.ex`
- Create: `elixir/test/symphony_elixir/claude_code/output_parser_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/symphony_elixir/claude_code/output_parser_test.exs
defmodule SymphonyElixir.ClaudeCode.OutputParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.OutputParser

  describe "parse_result/1" do
    test "parses successful result JSON" do
      json = ~s({"type":"result","session_id":"abc-123","result":"Done","cost_usd":0.05,"duration_ms":12345,"num_turns":3})
      assert {:ok, result} = OutputParser.parse_result(json)
      assert result.session_id == "abc-123"
      assert result.result == "Done"
      assert result.cost_usd == 0.05
    end

    test "parses error result JSON" do
      json = ~s({"type":"error","error":"Something went wrong"})
      assert {:error, "Something went wrong"} = OutputParser.parse_result(json)
    end

    test "handles invalid JSON" do
      assert {:error, _} = OutputParser.parse_result("not json{")
    end
  end

  describe "parse_streaming_line/1" do
    test "parses result line" do
      json = ~s({"type":"result","session_id":"abc-123","result":"Done","cost_usd":0.01,"duration_ms":500,"num_turns":1})
      assert {:result, result} = OutputParser.parse_streaming_line(json)
      assert result.session_id == "abc-123"
    end

    test "parses non-result JSON as message" do
      json = ~s({"type":"assistant","message":"Working..."})
      assert {:message, msg} = OutputParser.parse_streaming_line(json)
      assert msg["message"] == "Working..."
    end

    test "skips non-JSON lines" do
      assert :skip = OutputParser.parse_streaming_line("some log output")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/output_parser_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement OutputParser**

```elixir
# lib/symphony_elixir/claude_code/output_parser.ex
defmodule SymphonyElixir.ClaudeCode.OutputParser do
  @moduledoc "Parses Claude Code CLI JSON output."

  defmodule Result do
    @moduledoc false
    defstruct [:session_id, :result, :cost_usd, :duration_ms, :num_turns]
  end

  def parse_result(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"type" => "result"} = data} -> {:ok, to_result(data)}
      {:ok, %{"type" => "error", "error" => error}} -> {:error, error}
      {:ok, _} -> {:error, :unexpected_type}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  def parse_streaming_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = data} -> {:result, to_result(data)}
      {:ok, %{"type" => _} = data} -> {:message, data}
      _ -> :skip
    end
  end

  defp to_result(data) do
    %Result{
      session_id: data["session_id"],
      result: data["result"],
      cost_usd: data["cost_usd"],
      duration_ms: data["duration_ms"],
      num_turns: data["num_turns"]
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/output_parser_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/claude_code/output_parser.ex test/symphony_elixir/claude_code/output_parser_test.exs
git commit -m "feat: add Claude Code CLI output parser"
```

---

## Task 5: Claude Code Adapter

**Files:**
- Create: `elixir/lib/symphony_elixir/claude_code/adapter.ex`
- Create: `elixir/test/symphony_elixir/claude_code/adapter_test.exs`

Session state (session_id) is managed via an `Agent` process started in `start_session` and updated internally in `run_turn`. This keeps the behaviour contract at `{:ok, result_map}` — matching Codex.

- [ ] **Step 1: Write failing tests**

```elixir
# test/symphony_elixir/claude_code/adapter_test.exs
defmodule SymphonyElixir.ClaudeCode.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.Adapter

  describe "start_session/2" do
    test "returns session with Agent pid" do
      {:ok, session} = Adapter.start_session("/tmp/workspace", config: %{command: "claude"})
      assert is_pid(session.agent_pid)
      assert session.workspace == "/tmp/workspace"
      Adapter.stop_session(session)
    end
  end

  describe "build_command/3" do
    test "builds initial command without resume" do
      config = %{command: "claude", model: nil, additional_flags: []}
      cmd = Adapter.build_command(nil, "do something", config)
      assert cmd =~ "claude"
      assert cmd =~ "--dangerously-skip-permissions"
      assert cmd =~ "--output-format json"
      assert cmd =~ "-p"
      refute cmd =~ "--resume"
    end

    test "builds resume command with session_id" do
      config = %{command: "claude", model: nil, additional_flags: []}
      cmd = Adapter.build_command("session-abc", "continue", config)
      assert cmd =~ "--resume session-abc"
    end

    test "includes model flag when set" do
      config = %{command: "claude", model: "opus", additional_flags: []}
      cmd = Adapter.build_command(nil, "do it", config)
      assert cmd =~ "--model opus"
    end

    test "includes additional flags" do
      config = %{command: "claude", model: nil, additional_flags: ["--verbose"]}
      cmd = Adapter.build_command(nil, "do it", config)
      assert cmd =~ "--verbose"
    end
  end

  describe "stop_session/1" do
    test "stops Agent and returns :ok" do
      {:ok, session} = Adapter.start_session("/tmp/workspace", config: %{command: "claude"})
      assert :ok = Adapter.stop_session(session)
      refute Process.alive?(session.agent_pid)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/adapter_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement Claude Code adapter**

```elixir
# lib/symphony_elixir/claude_code/adapter.ex
defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  AgentAdapter implementation for Claude Code CLI.

  Uses Port.open for process management and an Agent process
  to manage session_id state across turns.
  """
  @behaviour SymphonyElixir.AgentAdapter

  alias SymphonyElixir.ClaudeCode.OutputParser

  require Logger

  defstruct [:agent_pid, :workspace, :config]

  @impl true
  def start_session(workspace, opts \\ []) do
    config = Keyword.get(opts, :config, %{})
    {:ok, agent_pid} = Agent.start_link(fn -> nil end)

    {:ok,
     %__MODULE__{
       agent_pid: agent_pid,
       workspace: workspace,
       config: config
     }}
  end

  @impl true
  def run_turn(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    config = session.config
    timeout_ms = Map.get(config, :turn_timeout_ms, 3_600_000)
    session_id = Agent.get(session.agent_pid, & &1)

    cmd = build_command(session_id, prompt, config)

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        {:cd, session.workspace}
      ])

    case receive_loop(port, on_message, timeout_ms, "") do
      {:ok, parsed_result} ->
        Agent.update(session.agent_pid, fn _ -> parsed_result.session_id end)

        on_message.(%{
          event: :turn_completed,
          timestamp: DateTime.utc_now(),
          session_id: parsed_result.session_id,
          cost_usd: parsed_result.cost_usd,
          duration_ms: parsed_result.duration_ms,
          num_turns: parsed_result.num_turns,
          result: parsed_result.result
        })

        {:ok, %{result: parsed_result.result, session_id: parsed_result.session_id}}

      {:error, reason} ->
        on_message.(%{
          event: :turn_failed,
          timestamp: DateTime.utc_now(),
          error: reason
        })

        {:error, reason}
    end
  end

  @impl true
  def stop_session(%__MODULE__{agent_pid: pid}) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  def stop_session(_), do: :ok

  @doc "Build the claude CLI command string."
  def build_command(session_id, prompt, config) do
    cmd = Map.get(config, :command, "claude")
    model = Map.get(config, :model)
    flags = Map.get(config, :additional_flags, [])
    escaped_prompt = escape_shell_arg(prompt)

    parts =
      [cmd, "--dangerously-skip-permissions", "--output-format json"] ++
        if(session_id, do: ["--resume", session_id], else: []) ++
        if(model, do: ["--model", model], else: []) ++
        flags ++
        ["-p", escaped_prompt]

    Enum.join(parts, " ")
  end

  defp escape_shell_arg(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp receive_loop(port, on_message, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = pending <> line

        case OutputParser.parse_streaming_line(full_line) do
          {:result, result} ->
            drain_port(port)
            {:ok, result}

          {:message, msg} ->
            on_message.(%{
              event: :notification,
              timestamp: DateTime.utc_now(),
              message: msg
            })
            receive_loop(port, on_message, timeout_ms, "")

          :skip ->
            receive_loop(port, on_message, timeout_ms, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending <> chunk)

      {^port, {:exit_status, 0}} ->
        {:error, :unexpected_clean_exit}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code}}
    after
      timeout_ms ->
        kill_port(port)
        {:error, :turn_timeout}
    end
  end

  defp drain_port(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, _} -> drain_port(port)
    after
      5_000 ->
        kill_port(port)
        :ok
    end
  end

  defp kill_port(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          Port.close(port)
          System.cmd("kill", ["-9", Integer.to_string(os_pid)])
        nil -> :ok
      end
    rescue
      _ -> :ok
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/adapter_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/claude_code/adapter.ex test/symphony_elixir/claude_code/adapter_test.exs
git commit -m "feat: add Claude Code CLI adapter with Port + Agent-based session"
```

---

## Task 6: Refactor AgentRunner to use AgentAdapter

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex:79-131`

- [ ] **Step 1: Run existing tests to establish baseline**

Run: `cd elixir && mix test --seed 0 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 2: Refactor AgentRunner — replace direct AppServer calls**

In `lib/symphony_elixir/agent_runner.ex`:

Replace alias:
```elixir
# Remove: alias SymphonyElixir.Codex.AppServer
# Add:
alias SymphonyElixir.AgentAdapter
```

Replace `run_codex_turns/5` (line 79-90):

```elixir
defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

  settings = Config.settings!()
  backend = settings.agent.backend
  adapter = AgentAdapter.adapter_for(backend)

  adapter_opts =
    case backend do
      "codex" -> [worker_host: worker_host]
      "claude_code" ->
        cc = settings.claude_code
        [config: %{
          command: cc.command,
          model: cc.model,
          additional_flags: cc.additional_flags,
          turn_timeout_ms: cc.turn_timeout_ms,
          stall_timeout_ms: cc.stall_timeout_ms
        }]
    end

  with {:ok, session} <- adapter.start_session(workspace, adapter_opts) do
    try do
      do_run_agent_turns(adapter, session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
    after
      adapter.stop_session(session)
    end
  end
end
```

Replace `do_run_codex_turns/8` (line 92-131). Preserve the exact `continue_with_issue?` return pattern:

```elixir
defp do_run_agent_turns(adapter, session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
  prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

  with {:ok, turn_result} <-
         adapter.run_turn(
           session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
    Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_result[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_agent_turns(
          adapter,
          session,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 3: Run all tests to verify no regression**

Run: `cd elixir && mix test --seed 0 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 4: Verify compilation without warnings**

Run: `cd elixir && mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: Compiled successfully

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent_runner.ex
git commit -m "refactor: AgentRunner uses AgentAdapter for backend dispatch

Replace direct Codex.AppServer calls with adapter dispatch.
Preserve continue_with_issue? pattern with refreshed_issue."
```

---

## Task 7: Config Schema — Add Slack embedded schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Write failing test for Slack config**

```elixir
test "slack config with defaults" do
  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"}
  })

  settings = Config.settings!()
  assert settings.slack.enabled == false
end

test "slack config with all fields" do
  System.put_env("TEST_SLACK_APP_TOKEN", "xapp-test")
  System.put_env("TEST_SLACK_BOT_TOKEN", "xoxb-test")

  on_exit(fn ->
    System.delete_env("TEST_SLACK_APP_TOKEN")
    System.delete_env("TEST_SLACK_BOT_TOKEN")
  end)

  write_workflow_file!(Workflow.workflow_file_path(), %{
    "tracker" => %{"kind" => "memory"},
    "workspace" => %{"root" => "/tmp/test"},
    "slack" => %{
      "enabled" => true,
      "app_token" => "$TEST_SLACK_APP_TOKEN",
      "bot_token" => "$TEST_SLACK_BOT_TOKEN",
      "notification_channel" => "#symphony-notifications"
    }
  })

  settings = Config.settings!()
  assert settings.slack.enabled == true
  assert settings.slack.app_token == "xapp-test"
  assert settings.slack.bot_token == "xoxb-test"
  assert settings.slack.notification_channel == "#symphony-notifications"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Add Slack embedded schema + resolve secrets in finalize_settings**

```elixir
defmodule Slack do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: false
    field :app_token, :string
    field :bot_token, :string
    field :notification_channel, :string
    field :summarization_model, :string, default: "claude-sonnet-4-6"
  end

  def changeset(schema \\ %__MODULE__{}, params) do
    schema
    |> cast(params, [:enabled, :app_token, :bot_token, :notification_channel, :summarization_model])
  end
end
```

Add to top-level embedded_schema:
```elixir
embeds_one(:slack, Slack, on_replace: :update, defaults_to_struct: true)
```

Add to changeset:
```elixir
|> cast_embed(:slack)
```

In `finalize_settings/1`, add Slack secret resolution following the existing pattern (the same way `tracker.api_key` is resolved):

```elixir
# After existing tracker secret resolution
slack = settings.slack
settings = %{settings | slack: %{slack |
  app_token: resolve_secret_setting(slack.app_token, nil),
  bot_token: resolve_secret_setting(slack.bot_token, nil)
}}
```

Note: `resolve_secret_setting/2` returns a plain value (string or nil), NOT a tuple. Follow the existing pattern at line ~371.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/core_test.exs
git commit -m "feat: add Slack config schema with secret resolution"
```

---

## Task 8: Add `fresh` dependency

**Files:**
- Modify: `elixir/mix.exs`

- [ ] **Step 1: Add fresh to deps in mix.exs**

```elixir
{:fresh, "~> 0.4"}
```

- [ ] **Step 2: Fetch dependencies and verify**

Run: `cd elixir && mix deps.get 2>&1 | tail -5 && mix compile 2>&1 | tail -5`
Expected: Fetched + compiled

- [ ] **Step 3: Verify fresh API is compatible — check docs**

Run: `cd elixir && mix deps 2>&1 | grep fresh`
Expected: Shows fresh version

- [ ] **Step 4: Commit**

```bash
cd elixir && git add mix.exs mix.lock
git commit -m "deps: add fresh ~> 0.4 for Slack Socket Mode WebSocket"
```

---

## Task 9: Slack API Client

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/api.ex`
- Create: `elixir/test/symphony_elixir/slack/api_test.exs`

- [ ] **Step 1: Write failing tests for helper functions**

```elixir
# test/symphony_elixir/slack/api_test.exs
defmodule SymphonyElixir.Slack.ApiTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Api

  describe "build_post_message_body/3" do
    test "builds message body for channel post" do
      body = Api.build_post_message_body("C123", "hello", nil)
      assert body["channel"] == "C123"
      assert body["text"] == "hello"
      refute Map.has_key?(body, "thread_ts")
    end

    test "builds message body for thread reply" do
      body = Api.build_post_message_body("C123", "hello", "1234567890.123456")
      assert body["thread_ts"] == "1234567890.123456"
    end
  end

  describe "build_replies_params/2" do
    test "builds conversations.replies params" do
      params = Api.build_replies_params("C123", "1234567890.123456")
      assert params["channel"] == "C123"
      assert params["ts"] == "1234567890.123456"
      assert params["inclusive"] == true
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/api_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement Slack API client**

```elixir
# lib/symphony_elixir/slack/api.ex
defmodule SymphonyElixir.Slack.Api do
  @moduledoc "Slack Web API client."

  require Logger

  @base_url "https://slack.com/api"

  def post_message(bot_token, channel, text, thread_ts \\ nil) do
    body = build_post_message_body(channel, text, thread_ts)
    post(bot_token, "chat.postMessage", body)
  end

  def conversations_replies(bot_token, channel, thread_ts) do
    params = build_replies_params(channel, thread_ts)
    get(bot_token, "conversations.replies", params)
  end

  def connections_open(app_token) do
    post(app_token, "apps.connections.open", %{})
  end

  def build_post_message_body(channel, text, nil) do
    %{"channel" => channel, "text" => text}
  end

  def build_post_message_body(channel, text, thread_ts) do
    %{"channel" => channel, "text" => text, "thread_ts" => thread_ts}
  end

  def build_replies_params(channel, thread_ts) do
    %{"channel" => channel, "ts" => thread_ts, "inclusive" => true}
  end

  defp post(token, method, body) do
    url = "#{@base_url}/#{method}"

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true} = resp}} -> {:ok, resp}
      {:ok, %{status: 200, body: %{"ok" => false, "error" => error}}} -> {:error, error}
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, get_retry_after(resp)}}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(token, method, params) do
    url = "#{@base_url}/#{method}"

    case Req.get(url,
           params: params,
           headers: [{"authorization", "Bearer #{token}"}]
         ) do
      {:ok, %{status: 200, body: %{"ok" => true} = resp}} -> {:ok, resp}
      {:ok, %{status: 200, body: %{"ok" => false, "error" => error}}} -> {:error, error}
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, get_retry_after(resp)}}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_retry_after(%{headers: headers}) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value) * 1000
      nil -> 5_000
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/api_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/api.ex test/symphony_elixir/slack/api_test.exs
git commit -m "feat: add Slack Web API client"
```

---

## Task 10: Slack Commands Parser

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/commands.ex`
- Create: `elixir/test/symphony_elixir/slack/commands_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/symphony_elixir/slack/commands_test.exs
defmodule SymphonyElixir.Slack.CommandsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Commands

  describe "parse/1" do
    test "parses ticket work command (Japanese)" do
      assert {:work, "MT-123"} = Commands.parse("MT-123 を対応して")
    end

    test "parses ticket work command (English)" do
      assert {:work, "MT-456"} = Commands.parse("work on MT-456")
    end

    test "bare ticket ID defaults to work" do
      assert {:work, "MT-789"} = Commands.parse("MT-789")
    end

    test "parses pause command" do
      assert {:pause, "MT-123"} = Commands.parse("pause MT-123")
    end

    test "parses retry command" do
      assert {:retry, "MT-123"} = Commands.parse("retry MT-123")
    end

    test "parses status command" do
      assert :status = Commands.parse("status")
    end

    test "free text defaults to implement" do
      assert {:implement, "この機能を追加してください"} = Commands.parse("この機能を追加してください")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/commands_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement Commands parser**

```elixir
# lib/symphony_elixir/slack/commands.ex
defmodule SymphonyElixir.Slack.Commands do
  @moduledoc "Parse Slack messages into Symphony commands."

  @ticket_pattern ~r/([A-Z]+-\d+)/

  @spec parse(String.t()) ::
          {:work, String.t()}
          | {:pause, String.t()}
          | {:retry, String.t()}
          | :status
          | {:implement, String.t()}
  def parse(text) do
    text = String.trim(text)

    cond do
      text =~ ~r/^pause\s+/i -> {:pause, extract_ticket(text)}
      text =~ ~r/^retry\s+/i -> {:retry, extract_ticket(text)}
      text =~ ~r/^status$/i -> :status
      Regex.match?(@ticket_pattern, text) -> {:work, extract_ticket(text)}
      true -> {:implement, text}
    end
  end

  defp extract_ticket(text) do
    case Regex.run(@ticket_pattern, text) do
      [_, ticket] -> ticket
      _ -> nil
    end
  end
end
```

Note: A bare ticket ID (`MT-789`) now defaults to `:work` rather than requiring specific keywords. This is more robust.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/commands_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/commands.ex test/symphony_elixir/slack/commands_test.exs
git commit -m "feat: add Slack command parser"
```

---

## Task 11: Slack Thread Context + Anthropic Summarization

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/thread_context.ex`
- Create: `elixir/test/symphony_elixir/slack/thread_context_test.exs`

- [ ] **Step 1: Write failing tests for pure functions**

```elixir
# test/symphony_elixir/slack/thread_context_test.exs
defmodule SymphonyElixir.Slack.ThreadContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.ThreadContext

  describe "format_thread_messages/1" do
    test "formats messages into readable text" do
      messages = [
        %{"user" => "U123", "text" => "We need a login page", "ts" => "1000.0"},
        %{"user" => "U456", "text" => "Should support OAuth", "ts" => "1001.0"}
      ]

      result = ThreadContext.format_thread_messages(messages)
      assert result =~ "We need a login page"
      assert result =~ "Should support OAuth"
    end
  end

  describe "build_ticket_description/2" do
    test "builds description with URL and summary" do
      desc = ThreadContext.build_ticket_description(
        "https://app.slack.com/archives/C123/p1234",
        "Build a login page with OAuth support"
      )

      assert desc =~ "## Slack Thread Context"
      assert desc =~ "https://app.slack.com/archives/C123/p1234"
      assert desc =~ "## Summary"
      assert desc =~ "Build a login page"
    end
  end

  describe "build_slack_thread_url/2" do
    test "builds permalink from channel and ts" do
      url = ThreadContext.build_slack_thread_url("C0123ABC", "1234567890.123456")
      assert url == "https://app.slack.com/archives/C0123ABC/p1234567890123456"
    end
  end

  describe "extract_title/1" do
    test "extracts first line as title" do
      assert "Login page implementation" = ThreadContext.extract_title("Login page implementation\nDetails here...")
    end

    test "strips markdown headers" do
      assert "Login page" = ThreadContext.extract_title("## Login page\nDetails...")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/thread_context_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement ThreadContext**

```elixir
# lib/symphony_elixir/slack/thread_context.ex
defmodule SymphonyElixir.Slack.ThreadContext do
  @moduledoc "Fetch Slack thread context and summarize via Anthropic API."

  alias SymphonyElixir.Slack.Api

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"

  def fetch_and_summarize(bot_token, channel, thread_ts, opts \\ []) do
    with {:ok, messages} <- fetch_thread(bot_token, channel, thread_ts),
         formatted = format_thread_messages(messages),
         thread_url = build_slack_thread_url(channel, thread_ts),
         {:ok, summary} <- summarize(formatted, opts) do
      {:ok,
       %{
         title: extract_title(summary),
         description: build_ticket_description(thread_url, summary),
         thread_url: thread_url
       }}
    end
  end

  def fetch_thread(bot_token, channel, thread_ts) do
    case Api.conversations_replies(bot_token, channel, thread_ts) do
      {:ok, %{"messages" => messages}} -> {:ok, messages}
      {:error, reason} -> {:error, {:slack_api, reason}}
    end
  end

  def format_thread_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      user = Map.get(msg, "user", "unknown")
      text = Map.get(msg, "text", "")
      "<#{user}>: #{text}"
    end)
    |> Enum.join("\n")
  end

  def build_ticket_description(thread_url, summary) do
    """
    ## Slack Thread Context
    [元スレッド](#{thread_url})

    ## Summary
    #{summary}
    """
    |> String.trim()
  end

  def build_slack_thread_url(channel, ts) do
    ts_compact = String.replace(ts, ".", "")
    "https://app.slack.com/archives/#{channel}/p#{ts_compact}"
  end

  def extract_title(summary) do
    summary
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.replace(~r/^#+\s*/, "")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp summarize(thread_text, opts) do
    api_key = Keyword.get(opts, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY"))
    model = Keyword.get(opts, :model, "claude-sonnet-4-6")

    if is_nil(api_key) do
      Logger.warning("ANTHROPIC_API_KEY not set, using raw thread text as summary")
      {:ok, thread_text}
    else
      call_anthropic(api_key, model, thread_text)
    end
  end

  defp call_anthropic(api_key, model, thread_text) do
    body = %{
      "model" => model,
      "max_tokens" => 1024,
      "messages" => [
        %{
          "role" => "user",
          "content" =>
            "以下のSlackスレッドの内容を、実装チケットの仕様として簡潔に要約してください。タイトル行を最初に書き、その後に詳細を書いてください。\n\n#{thread_text}"
        }
      ]
    }

    case Req.post(@anthropic_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} -> {:ok, text}
      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: status=#{status} body=#{inspect(body)}")
        {:error, {:anthropic_api, status}}
      {:error, reason} -> {:error, {:anthropic_api, reason}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/thread_context_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/thread_context.ex test/symphony_elixir/slack/thread_context_test.exs
git commit -m "feat: add Slack thread context fetcher with Anthropic summarization"
```

---

## Task 12: Slack Notifier GenServer

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/notifier.ex`
- Create: `elixir/test/symphony_elixir/slack/notifier_test.exs`

- [ ] **Step 1: Write failing tests for state management**

```elixir
# test/symphony_elixir/slack/notifier_test.exs
defmodule SymphonyElixir.Slack.NotifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Notifier

  describe "state management" do
    test "register_slack_origin stores thread mapping" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_slack_origin(state, "issue-1", "C123", "1234.5678")

      assert {:slack_origin, "C123", "1234.5678"} =
               Notifier.get_notification_target(state, "issue-1")
    end

    test "register_linear_origin creates notification channel target" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_linear_origin(state, "issue-2", "MT-123")

      assert {:notification_channel, "#notifications", nil} =
               Notifier.get_notification_target(state, "issue-2")
    end

    test "update_linear_thread_ts stores ts after first post" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_linear_origin(state, "issue-2", "MT-123")
      state = Notifier.update_linear_thread_ts(state, "issue-2", "9999.0000")

      assert {:notification_channel, "#notifications", "9999.0000"} =
               Notifier.get_notification_target(state, "issue-2")
    end

    test "unknown issue returns nil" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      assert nil == Notifier.get_notification_target(state, "unknown")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/notifier_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement Notifier GenServer**

```elixir
# lib/symphony_elixir/slack/notifier.ex
defmodule SymphonyElixir.Slack.Notifier do
  @moduledoc "Manages Slack notifications for Symphony issues."
  use GenServer

  alias SymphonyElixir.Slack.Api

  require Logger

  defstruct [:bot_token, :notification_channel, issue_targets: %{}]

  # Pure state functions (testable without GenServer)

  def new_state(bot_token, notification_channel) do
    %__MODULE__{bot_token: bot_token, notification_channel: notification_channel}
  end

  def register_slack_origin(state, issue_id, channel, thread_ts) do
    put_in(state.issue_targets[issue_id], {:slack_origin, channel, thread_ts})
  end

  def register_linear_origin(state, issue_id, _identifier) do
    put_in(state.issue_targets[issue_id], {:notification_channel, state.notification_channel, nil})
  end

  def update_linear_thread_ts(state, issue_id, thread_ts) do
    case state.issue_targets[issue_id] do
      {:notification_channel, channel, _} ->
        put_in(state.issue_targets[issue_id], {:notification_channel, channel, thread_ts})
      _ -> state
    end
  end

  def get_notification_target(state, issue_id) do
    Map.get(state.issue_targets, issue_id)
  end

  # GenServer API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def notify_state_change(issue_id, identifier, old_state, new_state) do
    GenServer.cast(__MODULE__, {:state_change, issue_id, identifier, old_state, new_state})
  end

  def notify_turn_complete(issue_id, identifier, summary) do
    GenServer.cast(__MODULE__, {:turn_complete, issue_id, identifier, summary})
  end

  def register_origin(issue_id, origin) do
    GenServer.cast(__MODULE__, {:register_origin, issue_id, origin})
  end

  @impl true
  def init(opts) do
    {:ok, new_state(Keyword.fetch!(opts, :bot_token), Keyword.fetch!(opts, :notification_channel))}
  end

  @impl true
  def handle_cast({:register_origin, issue_id, {:slack, channel, thread_ts}}, state) do
    {:noreply, register_slack_origin(state, issue_id, channel, thread_ts)}
  end

  def handle_cast({:register_origin, issue_id, {:linear, identifier}}, state) do
    {:noreply, register_linear_origin(state, issue_id, identifier)}
  end

  def handle_cast({:state_change, issue_id, identifier, _old, new_state_name}, state) do
    text = "`#{identifier}` ステータス: *#{new_state_name}*"
    {:noreply, post_to_target(state, issue_id, identifier, text)}
  end

  def handle_cast({:turn_complete, issue_id, identifier, summary}, state) do
    text = "`#{identifier}` ターン完了:\n#{summary}"
    {:noreply, post_to_target(state, issue_id, identifier, text)}
  end

  defp post_to_target(state, issue_id, identifier, text) do
    case get_notification_target(state, issue_id) do
      {:slack_origin, channel, thread_ts} ->
        Api.post_message(state.bot_token, channel, text, thread_ts)
        state

      {:notification_channel, channel, nil} ->
        case Api.post_message(state.bot_token, channel, "`#{identifier}`: #{text}") do
          {:ok, %{"ts" => ts}} -> update_linear_thread_ts(state, issue_id, ts)
          _ -> state
        end

      {:notification_channel, channel, thread_ts} ->
        Api.post_message(state.bot_token, channel, text, thread_ts)
        state

      nil ->
        Logger.debug("No notification target for issue #{issue_id}")
        state
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/notifier_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/notifier.ex test/symphony_elixir/slack/notifier_test.exs
git commit -m "feat: add Slack Notifier GenServer with thread mapping"
```

---

## Task 13: Slack Event Handler

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/event_handler.ex`
- Create: `elixir/test/symphony_elixir/slack/event_handler_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/symphony_elixir/slack/event_handler_test.exs
defmodule SymphonyElixir.Slack.EventHandlerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.EventHandler

  describe "handle_event/1" do
    test "routes app_mention to status command" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> status",
        "channel" => "C123",
        "ts" => "1234.5678",
        "user" => "U456"
      }

      assert {:command, :status, %{channel: "C123"}} =
               EventHandler.handle_event(event)
    end

    test "routes app_mention with ticket to work" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> MT-123 を対応して",
        "channel" => "C123",
        "ts" => "1234.5678",
        "user" => "U456"
      }

      assert {:command, {:work, "MT-123"}, _} = EventHandler.handle_event(event)
    end

    test "routes in-thread implement request" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> これを実装して",
        "channel" => "C123",
        "ts" => "1234.9999",
        "thread_ts" => "1234.0000",
        "user" => "U456"
      }

      assert {:implement_from_thread, _, %{thread_ts: "1234.0000"}} =
               EventHandler.handle_event(event)
    end

    test "ignores bot messages" do
      event = %{
        "type" => "app_mention",
        "text" => "something",
        "channel" => "C123",
        "ts" => "1234.5678",
        "bot_id" => "B123"
      }

      assert :ignore = EventHandler.handle_event(event)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/event_handler_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement EventHandler**

```elixir
# lib/symphony_elixir/slack/event_handler.ex
defmodule SymphonyElixir.Slack.EventHandler do
  @moduledoc "Routes Slack events to appropriate handlers."

  alias SymphonyElixir.Slack.Commands

  def handle_event(%{"bot_id" => _}), do: :ignore

  def handle_event(%{
        "type" => "app_mention",
        "text" => text,
        "channel" => channel,
        "ts" => ts
      } = event) do
    thread_ts = Map.get(event, "thread_ts")
    stripped = strip_mention(text)
    parsed = Commands.parse(stripped)
    context = %{channel: channel, ts: ts, thread_ts: thread_ts}

    case {parsed, thread_ts} do
      {{:implement, raw_text}, thread_ts} when is_binary(thread_ts) ->
        {:implement_from_thread, raw_text, context}

      {{:implement, raw_text}, nil} ->
        {:implement_direct, raw_text, context}

      {command, _} ->
        {:command, command, context}
    end
  end

  def handle_event(_), do: :ignore

  defp strip_mention(text) do
    Regex.replace(~r/<@[A-Z0-9]+>\s*/, text, "") |> String.trim()
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/event_handler_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/event_handler.ex test/symphony_elixir/slack/event_handler_test.exs
git commit -m "feat: add Slack event handler with command routing"
```

---

## Task 14: Slack Linear Actions

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/linear_actions.ex`
- Create: `elixir/test/symphony_elixir/slack/linear_actions_test.exs`

This module handles the Slack → Linear mutations (ticket creation, state changes).

- [ ] **Step 1: Write failing tests for ticket description building**

```elixir
# test/symphony_elixir/slack/linear_actions_test.exs
defmodule SymphonyElixir.Slack.LinearActionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.LinearActions

  describe "build_create_issue_mutation/3" do
    test "builds mutation with title and description" do
      {query, variables} = LinearActions.build_create_issue_mutation(
        "team-id-123",
        "Fix login bug",
        "Description here"
      )

      assert query =~ "issueCreate"
      assert variables["teamId"] == "team-id-123"
      assert variables["title"] == "Fix login bug"
      assert variables["description"] == "Description here"
    end
  end

  describe "build_update_state_mutation/2" do
    test "builds state update mutation" do
      {query, variables} = LinearActions.build_update_state_mutation("issue-id-123", "state-id-456")

      assert query =~ "issueUpdate"
      assert variables["issueId"] == "issue-id-123"
      assert variables["stateId"] == "state-id-456"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/linear_actions_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement LinearActions**

```elixir
# lib/symphony_elixir/slack/linear_actions.ex
defmodule SymphonyElixir.Slack.LinearActions do
  @moduledoc "Linear API mutations triggered from Slack commands."

  alias SymphonyElixir.Linear.Client

  require Logger

  def create_issue(title, description) do
    {query, variables} = build_create_issue_mutation(team_id(), title, description)

    case Client.graphql(query, variables) do
      {:ok, %{"data" => %{"issueCreate" => %{"issue" => issue}}}} ->
        {:ok, issue}

      {:error, reason} ->
        Logger.error("Failed to create Linear issue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def update_issue_state(issue_id, state_name) do
    with {:ok, state_id} <- find_state_id(state_name) do
      {query, variables} = build_update_state_mutation(issue_id, state_id)
      Client.graphql(query, variables)
    end
  end

  def build_create_issue_mutation(team_id, title, description) do
    query = """
    mutation IssueCreate($teamId: String!, $title: String!, $description: String) {
      issueCreate(input: {teamId: $teamId, title: $title, description: $description}) {
        issue {
          id
          identifier
          title
          url
        }
      }
    }
    """

    variables = %{"teamId" => team_id, "title" => title, "description" => description}
    {query, variables}
  end

  def build_update_state_mutation(issue_id, state_id) do
    query = """
    mutation IssueUpdate($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        issue {
          id
          identifier
          state { name }
        }
      }
    }
    """

    variables = %{"issueId" => issue_id, "stateId" => state_id}
    {query, variables}
  end

  defp team_id do
    SymphonyElixir.Config.settings!().tracker.project_slug
  end

  defp find_state_id(state_name) do
    query = """
    query WorkflowStates($teamId: String!) {
      team(id: $teamId) {
        states { nodes { id name } }
      }
    }
    """

    case Client.graphql(query, %{"teamId" => team_id()}) do
      {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => states}}}}} ->
        case Enum.find(states, &(&1["name"] == state_name)) do
          %{"id" => id} -> {:ok, id}
          nil -> {:error, {:state_not_found, state_name}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/linear_actions_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/linear_actions.ex test/symphony_elixir/slack/linear_actions_test.exs
git commit -m "feat: add Slack-to-Linear action module for ticket creation and state changes"
```

---

## Task 15: Slack Socket Mode GenServer

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/socket.ex`
- Create: `elixir/test/symphony_elixir/slack/socket_test.exs`

- [ ] **Step 1: Write failing tests for envelope processing**

```elixir
# test/symphony_elixir/slack/socket_test.exs
defmodule SymphonyElixir.Slack.SocketTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Socket

  describe "extract_event/1" do
    test "extracts event from events_api envelope" do
      envelope = %{
        "type" => "events_api",
        "payload" => %{
          "event" => %{
            "type" => "app_mention",
            "text" => "<@U123> status",
            "channel" => "C123",
            "ts" => "1234.5678",
            "user" => "U456"
          }
        }
      }

      assert {:ok, %{"type" => "app_mention"}} = Socket.extract_event(envelope)
    end

    test "returns :ignore for non-events_api" do
      assert :ignore = Socket.extract_event(%{"type" => "hello"})
    end
  end

  describe "reconnect_delay/1" do
    test "exponential backoff capped at 30 seconds" do
      assert Socket.reconnect_delay(0) == 1_000
      assert Socket.reconnect_delay(1) == 2_000
      assert Socket.reconnect_delay(2) == 4_000
      assert Socket.reconnect_delay(10) == 30_000
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/slack/socket_test.exs --seed 0 2>&1 | tail -10`
Expected: FAIL

- [ ] **Step 3: Implement Socket Mode GenServer**

```elixir
# lib/symphony_elixir/slack/socket.ex
defmodule SymphonyElixir.Slack.Socket do
  @moduledoc "Slack Socket Mode WebSocket connection manager."
  use GenServer

  alias SymphonyElixir.Slack.{Api, EventHandler, ThreadContext, Notifier, LinearActions}

  require Logger

  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000

  defstruct [:app_token, :bot_token, :ws_pid, :notification_channel, reconnect_attempts: 0]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public helpers (testable)

  def extract_event(%{"type" => "events_api", "payload" => %{"event" => event}}) do
    {:ok, event}
  end

  def extract_event(_), do: :ignore

  def reconnect_delay(attempts) do
    min(@reconnect_base_ms * (1 <<< attempts), @reconnect_max_ms)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      app_token: Keyword.fetch!(opts, :app_token),
      bot_token: Keyword.fetch!(opts, :bot_token),
      notification_channel: Keyword.fetch!(opts, :notification_channel)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, ws_pid} ->
        Logger.info("Slack Socket Mode connected")
        {:noreply, %{state | ws_pid: ws_pid, reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.error("Slack Socket Mode connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
        {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  def handle_info({:websocket, _pid, {:text, data}}, state) do
    case Jason.decode(data) do
      {:ok, %{"envelope_id" => envelope_id} = envelope} ->
        ack(state.ws_pid, envelope_id)

        case extract_event(envelope) do
          {:ok, event} -> dispatch_event(event, state)
          :ignore -> :ok
        end

      _ ->
        Logger.warning("Failed to parse Socket Mode message")
    end

    {:noreply, state}
  end

  def handle_info({:websocket, _pid, :closed}, state) do
    Logger.warning("Slack WebSocket closed, reconnecting...")
    schedule_reconnect(state)
    {:noreply, %{state | ws_pid: nil, reconnect_attempts: state.reconnect_attempts + 1}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp connect(state) do
    with {:ok, %{"url" => ws_url}} <- Api.connections_open(state.app_token) do
      Fresh.start_link(ws_url, __MODULE__, nil, [])
    end
  end

  defp ack(ws_pid, envelope_id) do
    payload = Jason.encode!(%{"envelope_id" => envelope_id})
    send(ws_pid, {:send, {:text, payload}})
  end

  defp schedule_reconnect(state) do
    delay = reconnect_delay(state.reconnect_attempts)
    Process.send_after(self(), :connect, delay)
  end

  defp dispatch_event(event, state) do
    case EventHandler.handle_event(event) do
      {:command, :status, context} ->
        Api.post_message(state.bot_token, context.channel, "ステータスを確認中...", context.ts)

      {:command, {:work, ticket_id}, context} ->
        Api.post_message(state.bot_token, context.channel, "`#{ticket_id}` の作業を開始します", context.ts)
        LinearActions.update_issue_state(ticket_id, "Todo")

      {:command, {:pause, ticket_id}, context} ->
        Api.post_message(state.bot_token, context.channel, "`#{ticket_id}` を一時停止します", context.ts)
        LinearActions.update_issue_state(ticket_id, "Backlog")

      {:command, {:retry, ticket_id}, context} ->
        Api.post_message(state.bot_token, context.channel, "`#{ticket_id}` をリトライします", context.ts)
        LinearActions.update_issue_state(ticket_id, "Todo")

      {:implement_from_thread, _text, context} ->
        handle_implement_from_thread(state, context)

      {:implement_direct, text, context} ->
        handle_implement_direct(state, text, context)

      :ignore ->
        :ok
    end
  end

  defp handle_implement_from_thread(state, context) do
    thread_ts = context.thread_ts

    Api.post_message(
      state.bot_token, context.channel,
      "スレッドの内容を確認してチケットを作成します...", thread_ts
    )

    Task.start(fn ->
      case ThreadContext.fetch_and_summarize(state.bot_token, context.channel, thread_ts) do
        {:ok, %{title: title, description: description}} ->
          case LinearActions.create_issue(title, description) do
            {:ok, %{"identifier" => identifier, "url" => url}} ->
              Notifier.register_origin(identifier, {:slack, context.channel, thread_ts})
              Api.post_message(
                state.bot_token, context.channel,
                "チケットを作成しました: <#{url}|#{identifier}> — #{title}", thread_ts
              )

            {:error, reason} ->
              Api.post_message(
                state.bot_token, context.channel,
                "エラー: チケット作成に失敗しました: #{inspect(reason)}", thread_ts
              )
          end

        {:error, reason} ->
          Logger.error("Thread context failed: #{inspect(reason)}")
          Api.post_message(
            state.bot_token, context.channel,
            "エラー: スレッドの取得に失敗しました", thread_ts
          )
      end
    end)
  end

  defp handle_implement_direct(state, text, context) do
    Api.post_message(
      state.bot_token, context.channel,
      "チケットを作成します...", context.ts
    )

    Task.start(fn ->
      title = String.slice(text, 0, 200)

      case LinearActions.create_issue(title, text) do
        {:ok, %{"identifier" => identifier, "url" => url}} ->
          Notifier.register_origin(identifier, {:slack, context.channel, context.ts})
          Api.post_message(
            state.bot_token, context.channel,
            "チケットを作成しました: <#{url}|#{identifier}>", context.ts
          )

        {:error, reason} ->
          Api.post_message(
            state.bot_token, context.channel,
            "エラー: チケット作成に失敗しました: #{inspect(reason)}", context.ts
          )
      end
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/slack/socket_test.exs --seed 0 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/socket.ex test/symphony_elixir/slack/socket_test.exs
git commit -m "feat: add Slack Socket Mode GenServer with full command dispatch"
```

---

## Task 16: Slack Supervisor

**Files:**
- Create: `elixir/lib/symphony_elixir/slack/supervisor.ex`

- [ ] **Step 1: Implement Slack Supervisor**

```elixir
# lib/symphony_elixir/slack/supervisor.ex
defmodule SymphonyElixir.Slack.Supervisor do
  @moduledoc "Supervises Slack subsystem (Socket + Notifier)."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    app_token = Keyword.fetch!(opts, :app_token)
    bot_token = Keyword.fetch!(opts, :bot_token)
    notification_channel = Keyword.fetch!(opts, :notification_channel)

    children = [
      {SymphonyElixir.Slack.Socket,
       app_token: app_token, bot_token: bot_token, notification_channel: notification_channel},
      {SymphonyElixir.Slack.Notifier,
       bot_token: bot_token, notification_channel: notification_channel}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd elixir && mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: Compiled

- [ ] **Step 3: Commit**

```bash
cd elixir && git add lib/symphony_elixir/slack/supervisor.ex
git commit -m "feat: add Slack.Supervisor with :rest_for_one strategy"
```

---

## Task 17: Wire Slack into Application Supervision Tree

**Files:**
- Modify: `elixir/lib/symphony_elixir.ex:20-40`

- [ ] **Step 1: Add conditional Slack.Supervisor to children**

In `lib/symphony_elixir.ex`, add helper and modify children list:

```elixir
defp slack_children do
  try do
    settings = SymphonyElixir.Config.settings!()

    if settings.slack.enabled do
      [
        {SymphonyElixir.Slack.Supervisor,
         app_token: settings.slack.app_token,
         bot_token: settings.slack.bot_token,
         notification_channel: settings.slack.notification_channel}
      ]
    else
      []
    end
  rescue
    _ -> []
  end
end
```

Append to children list:
```elixir
children = [...existing children...] ++ slack_children()
```

- [ ] **Step 2: Verify compilation + run all tests**

Run: `cd elixir && mix compile --warnings-as-errors 2>&1 | tail -5 && mix test --seed 0 2>&1 | tail -10`
Expected: Compiled + all tests pass

- [ ] **Step 3: Commit**

```bash
cd elixir && git add lib/symphony_elixir.ex
git commit -m "feat: wire Slack.Supervisor into application (conditional on slack.enabled)"
```

---

## Task 18: Add Notification Hooks to Orchestrator

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

- [ ] **Step 1: Add notification helper functions**

Add private helper functions to orchestrator.ex:

```elixir
defp maybe_notify_slack_state_change(issue_id, identifier, old_state, new_state) do
  if slack_enabled?() do
    SymphonyElixir.Slack.Notifier.notify_state_change(issue_id, identifier, old_state, new_state)
  end
end

defp maybe_notify_slack_turn_complete(issue_id, identifier, summary) do
  if slack_enabled?() do
    SymphonyElixir.Slack.Notifier.notify_turn_complete(issue_id, identifier, summary)
  end
end

defp maybe_register_linear_origin(issue) do
  if slack_enabled?() do
    SymphonyElixir.Slack.Notifier.register_origin(issue.id, {:linear, issue.identifier})
  end
end

defp slack_enabled? do
  case SymphonyElixir.Config.settings!() do
    %{slack: %{enabled: true}} -> true
    _ -> false
  end
end
```

- [ ] **Step 2: Hook into codex_worker_update for turn completion**

In `handle_info({:codex_worker_update, ...}, state)` (around line 183-202), after `integrate_codex_update`:

```elixir
if update.event == :turn_completed do
  summary = Map.get(update, :result, "Turn completed")
  maybe_notify_slack_turn_complete(issue_id, running_entry.identifier, summary)
end
```

- [ ] **Step 3: Hook into dispatch flow for origin registration**

In the dispatch/spawn flow (where new issues are picked up), add:

```elixir
maybe_register_linear_origin(issue)
```

- [ ] **Step 4: Run all tests**

Run: `cd elixir && mix test --seed 0 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/orchestrator.ex
git commit -m "feat: add Slack notification hooks to Orchestrator"
```

---

## Task 19: Integration Test — Claude Code Adapter

**Files:**
- Create: `elixir/test/symphony_elixir/claude_code/integration_test.exs`

- [ ] **Step 1: Write integration test (tagged, skipped by default)**

```elixir
defmodule SymphonyElixir.ClaudeCode.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  alias SymphonyElixir.ClaudeCode.Adapter

  test "run a simple Claude Code turn" do
    workspace = Path.join(System.tmp_dir!(), "symphony_cc_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, session} = Adapter.start_session(workspace, config: %{
      command: "claude",
      model: nil,
      additional_flags: [],
      turn_timeout_ms: 60_000
    })

    on_exit(fn -> Adapter.stop_session(session) end)

    case Adapter.run_turn(session, "Write 'hello' to a file called test.txt", %{}, on_message: fn _ -> :ok end) do
      {:ok, result} ->
        assert is_binary(result.result)
        IO.puts("Claude Code result: #{result.result}")

      {:error, reason} ->
        flunk("Claude Code turn failed: #{inspect(reason)}")
    end
  end
end
```

- [ ] **Step 2: Run manually (requires claude CLI)**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/integration_test.exs --include integration 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
cd elixir && git add test/symphony_elixir/claude_code/integration_test.exs
git commit -m "test: add Claude Code adapter integration test"
```

---

## Task 20: Full Test Suite + Lint + Format

- [ ] **Step 1: Run full test suite**

Run: `cd elixir && mix test --seed 0 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 2: Format**

Run: `cd elixir && mix format`

- [ ] **Step 3: Lint**

Run: `cd elixir && mix credo --strict 2>&1 | tail -20`

- [ ] **Step 4: Dialyzer**

Run: `cd elixir && mix dialyzer 2>&1 | tail -20`

- [ ] **Step 5: Fix any issues, then commit**

```bash
cd elixir && git add -A
git commit -m "chore: fix formatting, lint, and dialyzer issues"
```

---

## Summary

| # | Task | Type | Depends On |
|---|------|------|------------|
| 1 | Config Schema: backend + ClaudeCode | Config | — |
| 2 | AgentAdapter Behaviour | Interface | — |
| 3 | Codex Adapter (wrap AppServer) | Adapter | 2 |
| 4 | Claude Code Output Parser | Parser | — |
| 5 | Claude Code Adapter | Adapter | 2, 4 |
| 6 | Refactor AgentRunner | Refactor | 1, 2, 3, 5 |
| 7 | Config Schema: Slack | Config | — |
| 8 | Add `fresh` dependency | Deps | — |
| 9 | Slack API Client | HTTP | — |
| 10 | Slack Commands Parser | Parser | — |
| 11 | Slack Thread Context | Feature | 9 |
| 12 | Slack Notifier GenServer | Feature | 9 |
| 13 | Slack Event Handler | Feature | 10 |
| 14 | Slack Linear Actions | Feature | — |
| 15 | Slack Socket Mode GenServer | Feature | 8, 9, 11, 12, 13, 14 |
| 16 | Slack Supervisor | Infra | 15, 12 |
| 17 | Wire into Supervision Tree | Infra | 7, 16 |
| 18 | Orchestrator Notification Hooks | Integration | 6, 12 |
| 19 | Claude Code Integration Test | Test | 5 |
| 20 | Full Test Suite + Lint | QA | All |

**Parallelizable groups:**
- Tasks 1, 2, 4, 7, 8, 9, 10, 14 — all independent, can run in parallel
- Tasks 3, 5 — depend on 2 (and 4 for 5)
- Tasks 11, 12, 13 — depend on 9 or 10
- Tasks 6, 15-20 — sequential integration phase
