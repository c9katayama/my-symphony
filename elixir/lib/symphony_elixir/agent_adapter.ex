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
