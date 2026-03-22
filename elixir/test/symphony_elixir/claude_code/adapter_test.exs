defmodule SymphonyElixir.ClaudeCode.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.Adapter

  describe "start_session/2" do
    test "returns session with Agent pid" do
      {:ok, session} = Adapter.start_session("/tmp/workspace", config: %{command: "claude"})
      assert is_pid(session.agent_pid)
      assert session.workspace == "/tmp/workspace"
      Adapter.stop_session(session)
    end
  end

  describe "build_command/3" do
    test "builds initial command without resume" do
      config = %{command: "claude", model: nil, additional_flags: []}
      cmd = Adapter.build_command(nil, "do something", config)
      assert cmd =~ "claude"
      assert cmd =~ "--dangerously-skip-permissions"
      assert cmd =~ "--output-format json"
      assert cmd =~ "-p"
      refute cmd =~ "--resume"
    end

    test "builds resume command with session_id" do
      config = %{command: "claude", model: nil, additional_flags: []}
      cmd = Adapter.build_command("session-abc", "continue", config)
      assert cmd =~ "--resume session-abc"
    end

    test "includes model flag when set" do
      config = %{command: "claude", model: "opus", additional_flags: []}
      cmd = Adapter.build_command(nil, "do it", config)
      assert cmd =~ "--model opus"
    end

    test "includes additional flags" do
      config = %{command: "claude", model: nil, additional_flags: ["--verbose"]}
      cmd = Adapter.build_command(nil, "do it", config)
      assert cmd =~ "--verbose"
    end
  end

  describe "stop_session/1" do
    test "stops Agent and returns :ok" do
      {:ok, session} = Adapter.start_session("/tmp/workspace", config: %{command: "claude"})
      assert :ok = Adapter.stop_session(session)
      refute Process.alive?(session.agent_pid)
    end
  end
end
