defmodule SymphonyElixir.Slack.ThreadContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.ThreadContext

  describe "format_thread_messages/1" do
    test "formats messages into readable text" do
      messages = [
        %{"user" => "U123", "text" => "We need a login page", "ts" => "1000.0"},
        %{"user" => "U456", "text" => "Should support OAuth", "ts" => "1001.0"}
      ]

      result = ThreadContext.format_thread_messages(messages)
      assert result =~ "We need a login page"
      assert result =~ "Should support OAuth"
    end
  end

  describe "build_ticket_description/2" do
    test "builds description with URL and summary" do
      desc = ThreadContext.build_ticket_description(
        "https://app.slack.com/archives/C123/p1234",
        "Build a login page with OAuth support"
      )

      assert desc =~ "## Slack Thread Context"
      assert desc =~ "https://app.slack.com/archives/C123/p1234"
      assert desc =~ "## Summary"
      assert desc =~ "Build a login page"
    end
  end

  describe "build_slack_thread_url/2" do
    test "builds permalink from channel and ts" do
      url = ThreadContext.build_slack_thread_url("C0123ABC", "1234567890.123456")
      assert url == "https://app.slack.com/archives/C0123ABC/p1234567890123456"
    end
  end

  describe "extract_title/1" do
    test "extracts first line as title" do
      assert "Login page implementation" = ThreadContext.extract_title("Login page implementation\nDetails here...")
    end

    test "strips markdown headers" do
      assert "Login page" = ThreadContext.extract_title("## Login page\nDetails...")
    end
  end
end
