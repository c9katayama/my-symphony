defmodule SymphonyElixir.Slack.Socket do
  @moduledoc "Slack Socket Mode WebSocket connection manager."
  use GenServer

  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.Slack.{Api, EventHandler, LinearActions, Notifier, ThreadContext}

  require Logger

  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000

  defstruct [:app_token, :bot_token, :ws_pid, reconnect_attempts: 0]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec extract_event(map()) :: {:ok, map()} | :ignore
  def extract_event(%{"type" => "events_api", "payload" => %{"event" => event}}), do: {:ok, event}
  def extract_event(_), do: :ignore

  @spec reconnect_delay(non_neg_integer()) :: pos_integer()
  def reconnect_delay(attempts) do
    min(@reconnect_base_ms * (1 <<< attempts), @reconnect_max_ms)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      app_token: Keyword.fetch!(opts, :app_token),
      bot_token: Keyword.fetch!(opts, :bot_token)
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
      state.bot_token,
      context.channel,
      "スレッドの内容を確認してチケットを作成します...",
      thread_ts
    )

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      do_implement_from_thread(state.bot_token, context.channel, thread_ts)
    end)
  end

  defp do_implement_from_thread(bot_token, channel, thread_ts) do
    case ThreadContext.fetch_and_summarize(bot_token, channel, thread_ts) do
      {:ok, %{title: title, description: description}} ->
        case LinearActions.create_issue(title, description) do
          {:ok, %{"identifier" => identifier, "url" => url}} ->
            Notifier.register_origin(identifier, {:slack, channel, thread_ts})
            Api.post_message(bot_token, channel, "チケットを作成しました: <#{url}|#{identifier}> — #{title}", thread_ts)

          {:error, reason} ->
            Api.post_message(bot_token, channel, "エラー: チケット作成に失敗しました: #{inspect(reason)}", thread_ts)
        end

      {:error, reason} ->
        Logger.error("Thread context failed: #{inspect(reason)}")
        Api.post_message(bot_token, channel, "エラー: スレッドの取得に失敗しました", thread_ts)
    end
  end

  defp handle_implement_direct(state, text, context) do
    Api.post_message(
      state.bot_token,
      context.channel,
      "チケットを作成します...",
      context.ts
    )

    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      title = String.slice(text, 0, 200)

      case LinearActions.create_issue(title, text) do
        {:ok, %{"identifier" => identifier, "url" => url}} ->
          Notifier.register_origin(identifier, {:slack, context.channel, context.ts})

          Api.post_message(
            state.bot_token,
            context.channel,
            "チケットを作成しました: <#{url}|#{identifier}>",
            context.ts
          )

        {:error, reason} ->
          Api.post_message(
            state.bot_token,
            context.channel,
            "エラー: チケット作成に失敗しました: #{inspect(reason)}",
            context.ts
          )
      end
    end)
  end
end
