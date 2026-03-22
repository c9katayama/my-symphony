defmodule SymphonyElixir.Slack.EventHandler do
  @moduledoc "Routes Slack events to appropriate handlers."

  alias SymphonyElixir.Slack.Commands

  @spec handle_event(map()) ::
          {:command, term(), map()}
          | {:implement_from_thread, String.t(), map()}
          | {:implement_direct, String.t(), map()}
          | :ignore
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
