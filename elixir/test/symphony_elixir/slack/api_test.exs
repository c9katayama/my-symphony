defmodule SymphonyElixir.Slack.ApiTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Api

  describe "build_post_message_body/3" do
    test "builds message body without thread_ts" do
      body = Api.build_post_message_body("C123", "hello", nil)
      assert body["channel"] == "C123"
      assert body["text"] == "hello"
      refute Map.has_key?(body, "thread_ts")
    end

    test "builds message body with thread_ts" do
      body = Api.build_post_message_body("C123", "hello", "1234567890.123456")
      assert body["thread_ts"] == "1234567890.123456"
    end
  end

  describe "build_replies_params/2" do
    test "builds conversations.replies params" do
      params = Api.build_replies_params("C123", "1234567890.123456")
      assert params["channel"] == "C123"
      assert params["ts"] == "1234567890.123456"
      assert params["inclusive"] == true
    end
  end
end
