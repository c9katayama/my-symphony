defmodule SymphonyElixir.Slack.Notifier do
  @moduledoc "Manages Slack notifications for Symphony issues."
  use GenServer

  alias SymphonyElixir.Slack.Api

  require Logger

  defstruct [:bot_token, :notification_channel, issue_targets: %{}]

  # Pure state functions (testable without GenServer)

  @spec new_state(String.t(), String.t()) :: %__MODULE__{}
  def new_state(bot_token, notification_channel) do
    %__MODULE__{bot_token: bot_token, notification_channel: notification_channel}
  end

  @spec register_slack_origin(%__MODULE__{}, String.t(), String.t(), String.t()) :: %__MODULE__{}
  def register_slack_origin(state, issue_id, channel, thread_ts) do
    put_in(state.issue_targets[issue_id], {:slack_origin, channel, thread_ts})
  end

  @spec register_linear_origin(%__MODULE__{}, String.t(), String.t()) :: %__MODULE__{}
  def register_linear_origin(state, issue_id, _identifier) do
    put_in(state.issue_targets[issue_id], {:notification_channel, state.notification_channel, nil})
  end

  @spec update_linear_thread_ts(%__MODULE__{}, String.t(), String.t()) :: %__MODULE__{}
  def update_linear_thread_ts(state, issue_id, thread_ts) do
    case state.issue_targets[issue_id] do
      {:notification_channel, channel, _} ->
        put_in(state.issue_targets[issue_id], {:notification_channel, channel, thread_ts})
      _ -> state
    end
  end

  @spec get_notification_target(%__MODULE__{}, String.t()) :: term()
  def get_notification_target(state, issue_id) do
    Map.get(state.issue_targets, issue_id)
  end

  # GenServer API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec notify_state_change(String.t(), String.t(), String.t(), String.t()) :: :ok
  def notify_state_change(issue_id, identifier, old_state, new_state) do
    GenServer.cast(__MODULE__, {:state_change, issue_id, identifier, old_state, new_state})
  end

  @spec notify_turn_complete(String.t(), String.t(), String.t()) :: :ok
  def notify_turn_complete(issue_id, identifier, summary) do
    GenServer.cast(__MODULE__, {:turn_complete, issue_id, identifier, summary})
  end

  @spec register_origin(String.t(), term()) :: :ok
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

  defp post_to_target(state, issue_id, _identifier, text) do
    case get_notification_target(state, issue_id) do
      {:slack_origin, channel, thread_ts} ->
        Api.post_message(state.bot_token, channel, text, thread_ts)
        state

      {:notification_channel, channel, nil} ->
        case Api.post_message(state.bot_token, channel, text) do
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
