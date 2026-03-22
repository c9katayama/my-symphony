defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  AgentAdapter implementation for Claude Code CLI.

  Uses Port.open for process management and an Agent process
  to manage session_id state across turns, keeping the behaviour
  contract at {:ok, result_map} (2-tuple).
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
  def run_turn(%__MODULE__{} = session, prompt, _issue, opts \\ []) do
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
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Port.close(port)
        System.cmd("kill", ["-9", Integer.to_string(os_pid)])

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
