defmodule SymphonyElixir.Slack.EventHandlerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.EventHandler

  describe "handle_event/1" do
    test "routes app_mention to status command" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> status",
        "channel" => "C123",
        "ts" => "1234.5678",
        "user" => "U456"
      }

      assert {:command, :status, %{channel: "C123"}} =
               EventHandler.handle_event(event)
    end

    test "routes app_mention with ticket to work" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> MT-123 を対応して",
        "channel" => "C123",
        "ts" => "1234.5678",
        "user" => "U456"
      }

      assert {:command, {:work, "MT-123"}, _} = EventHandler.handle_event(event)
    end

    test "routes in-thread implement request" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U123BOT> これを実装して",
        "channel" => "C123",
        "ts" => "1234.9999",
        "thread_ts" => "1234.0000",
        "user" => "U456"
      }

      assert {:implement_from_thread, _, %{thread_ts: "1234.0000"}} =
               EventHandler.handle_event(event)
    end

    test "ignores bot messages" do
      event = %{
        "type" => "app_mention",
        "text" => "something",
        "channel" => "C123",
        "ts" => "1234.5678",
        "bot_id" => "B123"
      }

      assert :ignore = EventHandler.handle_event(event)
    end
  end
end
