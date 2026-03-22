defmodule SymphonyElixir.Slack.LinearActions do
  @moduledoc "Linear API mutations triggered from Slack commands."

  alias SymphonyElixir.Linear.Client

  require Logger

  def create_issue(title, description) do
    settings = SymphonyElixir.Config.settings!()
    team_id = settings.tracker.project_slug

    {query, variables} = build_create_issue_mutation(team_id, title, description)

    case Client.graphql(query, variables) do
      {:ok, %{"data" => %{"issueCreate" => %{"issue" => issue}}}} ->
        {:ok, issue}

      {:error, reason} ->
        Logger.error("Failed to create Linear issue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def update_issue_state(issue_identifier, state_name) do
    settings = SymphonyElixir.Config.settings!()
    team_id = settings.tracker.project_slug

    with {:ok, state_id} <- find_state_id(team_id, state_name),
         {:ok, issue_id} <- find_issue_id(issue_identifier) do
      {query, variables} = build_update_state_mutation(issue_id, state_id)

      case Client.graphql(query, variables) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def build_create_issue_mutation(team_id, title, description) do
    query = """
    mutation IssueCreate($teamId: String!, $title: String!, $description: String) {
      issueCreate(input: {teamId: $teamId, title: $title, description: $description}) {
        issue {
          id
          identifier
          title
          url
        }
      }
    }
    """

    variables = %{"teamId" => team_id, "title" => title, "description" => description}
    {query, variables}
  end

  def build_update_state_mutation(issue_id, state_id) do
    query = """
    mutation IssueUpdate($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        issue {
          id
          identifier
          state { name }
        }
      }
    }
    """

    variables = %{"issueId" => issue_id, "stateId" => state_id}
    {query, variables}
  end

  defp find_state_id(team_id, state_name) do
    query = """
    query WorkflowStates($teamId: String!) {
      team(id: $teamId) {
        states { nodes { id name } }
      }
    }
    """

    case Client.graphql(query, %{"teamId" => team_id}) do
      {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => states}}}}} ->
        case Enum.find(states, &(&1["name"] == state_name)) do
          %{"id" => id} -> {:ok, id}
          nil -> {:error, {:state_not_found, state_name}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_issue_id(identifier) do
    query = """
    query IssueByIdentifier($identifier: String!) {
      issueSearch(filter: {identifier: {eq: $identifier}}) {
        nodes { id identifier }
      }
    }
    """

    case Client.graphql(query, %{"identifier" => identifier}) do
      {:ok, %{"data" => %{"issueSearch" => %{"nodes" => [%{"id" => id} | _]}}}} ->
        {:ok, id}

      {:ok, %{"data" => %{"issueSearch" => %{"nodes" => []}}}} ->
        {:error, {:issue_not_found, identifier}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
