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
