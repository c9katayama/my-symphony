defmodule SymphonyElixir.Slack.Supervisor do
  @moduledoc "Supervises Slack subsystem (Notifier + Socket)."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    app_token = Keyword.fetch!(opts, :app_token)
    bot_token = Keyword.fetch!(opts, :bot_token)
    notification_channel = Keyword.fetch!(opts, :notification_channel)

    # Notifier must start before Socket (Socket depends on Notifier for register_origin calls)
    children = [
      {SymphonyElixir.Slack.Notifier, bot_token: bot_token, notification_channel: notification_channel},
      {SymphonyElixir.Slack.Socket, app_token: app_token, bot_token: bot_token}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
