defmodule SymphonyElixir.Slack.NotifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Notifier

  describe "state management" do
    test "register_slack_origin stores thread mapping" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_slack_origin(state, "issue-1", "C123", "1234.5678")

      assert {:slack_origin, "C123", "1234.5678"} =
               Notifier.get_notification_target(state, "issue-1")
    end

    test "register_linear_origin creates notification channel target" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_linear_origin(state, "issue-2", "MT-123")

      assert {:notification_channel, "#notifications", nil} =
               Notifier.get_notification_target(state, "issue-2")
    end

    test "update_linear_thread_ts stores ts after first post" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      state = Notifier.register_linear_origin(state, "issue-2", "MT-123")
      state = Notifier.update_linear_thread_ts(state, "issue-2", "9999.0000")

      assert {:notification_channel, "#notifications", "9999.0000"} =
               Notifier.get_notification_target(state, "issue-2")
    end

    test "unknown issue returns nil" do
      state = Notifier.new_state("xoxb-test", "#notifications")
      assert nil == Notifier.get_notification_target(state, "unknown")
    end
  end
end
