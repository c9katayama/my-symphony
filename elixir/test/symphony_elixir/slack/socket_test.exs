defmodule SymphonyElixir.Slack.SocketTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Socket

  describe "extract_event/1" do
    test "extracts event from events_api envelope" do
      envelope = %{
        "type" => "events_api",
        "payload" => %{
          "event" => %{
            "type" => "app_mention",
            "text" => "<@U123> status",
            "channel" => "C123",
            "ts" => "1234.5678",
            "user" => "U456"
          }
        }
      }

      assert {:ok, %{"type" => "app_mention"}} = Socket.extract_event(envelope)
    end

    test "returns :ignore for non-events_api" do
      assert :ignore = Socket.extract_event(%{"type" => "hello"})
    end
  end

  describe "reconnect_delay/1" do
    test "exponential backoff capped at 30 seconds" do
      assert Socket.reconnect_delay(0) == 1_000
      assert Socket.reconnect_delay(1) == 2_000
      assert Socket.reconnect_delay(2) == 4_000
      assert Socket.reconnect_delay(10) == 30_000
    end
  end
end
