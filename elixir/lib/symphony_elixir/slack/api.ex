defmodule SymphonyElixir.Slack.Api do
  @moduledoc "Slack Web API client."

  require Logger

  @base_url "https://slack.com/api"

  @spec post_message(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def post_message(bot_token, channel, text, thread_ts \\ nil) do
    body = build_post_message_body(channel, text, thread_ts)
    post(bot_token, "chat.postMessage", body)
  end

  @spec conversations_replies(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def conversations_replies(bot_token, channel, thread_ts) do
    params = build_replies_params(channel, thread_ts)
    get(bot_token, "conversations.replies", params)
  end

  @spec connections_open(String.t()) :: {:ok, map()} | {:error, term()}
  def connections_open(app_token) do
    post(app_token, "apps.connections.open", %{})
  end

  @spec build_post_message_body(String.t(), String.t(), String.t() | nil) :: map()
  def build_post_message_body(channel, text, nil) do
    %{"channel" => channel, "text" => text}
  end

  def build_post_message_body(channel, text, thread_ts) do
    %{"channel" => channel, "text" => text, "thread_ts" => thread_ts}
  end

  @spec build_replies_params(String.t(), String.t()) :: map()
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
      {:ok, %{status: 200, body: body}} -> {:error, {:unexpected_response, body}}
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
      {:ok, %{status: 200, body: body}} -> {:error, {:unexpected_response, body}}
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, get_retry_after(resp)}}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_retry_after(%{headers: headers}) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> 5_000
        end

      nil ->
        5_000
    end
  end
end
