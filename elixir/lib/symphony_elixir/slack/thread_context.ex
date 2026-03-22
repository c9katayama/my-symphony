defmodule SymphonyElixir.Slack.ThreadContext do
  @moduledoc "Fetch Slack thread context and summarize via Anthropic API."

  alias SymphonyElixir.Slack.Api

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"

  @spec fetch_and_summarize(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{title: String.t(), description: String.t(), thread_url: String.t()}}
          | {:error, term()}
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

  @spec fetch_thread(String.t(), String.t(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def fetch_thread(bot_token, channel, thread_ts) do
    case Api.conversations_replies(bot_token, channel, thread_ts) do
      {:ok, %{"messages" => messages}} -> {:ok, messages}
      {:error, reason} -> {:error, {:slack_api, reason}}
    end
  end

  @spec format_thread_messages(list(map())) :: String.t()
  def format_thread_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      user = Map.get(msg, "user", "unknown")
      text = Map.get(msg, "text", "")
      "<#{user}>: #{text}"
    end)
    |> Enum.join("\n")
  end

  @spec build_ticket_description(String.t(), String.t()) :: String.t()
  def build_ticket_description(thread_url, summary) do
    """
    ## Slack Thread Context
    [元スレッド](#{thread_url})

    ## Summary
    #{summary}
    """
    |> String.trim()
  end

  @spec build_slack_thread_url(String.t(), String.t()) :: String.t()
  def build_slack_thread_url(channel, ts) do
    ts_compact = String.replace(ts, ".", "")
    "https://app.slack.com/archives/#{channel}/p#{ts_compact}"
  end

  @spec extract_title(String.t()) :: String.t()
  def extract_title(""), do: ""

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
          "content" => "以下のSlackスレッドの内容を、実装チケットの仕様として簡潔に要約してください。タイトル行を最初に書き、その後に詳細を書いてください。\n\n#{thread_text}"
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
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: status=#{status} body=#{inspect(body)}")
        {:error, {:anthropic_api, status}}

      {:error, reason} ->
        {:error, {:anthropic_api, reason}}
    end
  end
end
