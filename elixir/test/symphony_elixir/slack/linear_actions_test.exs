defmodule SymphonyElixir.Slack.LinearActionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.LinearActions

  describe "build_create_issue_mutation/3" do
    test "builds mutation with title and description" do
      {query, variables} =
        LinearActions.build_create_issue_mutation("team-id-123", "Fix login bug", "Description")

      assert query =~ "issueCreate"
      assert variables["teamId"] == "team-id-123"
      assert variables["title"] == "Fix login bug"
      assert variables["description"] == "Description"
    end
  end

  describe "build_update_state_mutation/2" do
    test "builds state update mutation" do
      {query, variables} = LinearActions.build_update_state_mutation("issue-id-123", "state-id-456")

      assert query =~ "issueUpdate"
      assert variables["issueId"] == "issue-id-123"
      assert variables["stateId"] == "state-id-456"
    end
  end
end
