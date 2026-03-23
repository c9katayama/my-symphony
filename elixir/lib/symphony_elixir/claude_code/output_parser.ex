defmodule SymphonyElixir.ClaudeCode.OutputParser do
  @moduledoc "Parses Claude Code CLI JSON output."

  defmodule Result do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:session_id, :result, :cost_usd, :duration_ms, :num_turns]
  end

  alias __MODULE__.Result

  @spec parse_result(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def parse_result(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"type" => "result"} = data} -> {:ok, to_result(data)}
      {:ok, %{"type" => "error", "error" => error}} -> {:error, error}
      {:ok, _} -> {:error, :unexpected_type}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  @spec parse_streaming_line(String.t()) :: {:message, map()} | {:result, Result.t()} | :skip
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
