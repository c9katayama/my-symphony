defmodule SymphonyElixir.AgentAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentAdapter

  test "adapter_for returns Codex adapter" do
    assert AgentAdapter.adapter_for("codex") == SymphonyElixir.Codex.Adapter
  end

  test "adapter_for returns Claude Code adapter" do
    assert AgentAdapter.adapter_for("claude_code") == SymphonyElixir.ClaudeCode.Adapter
  end

  test "adapter_for raises on unknown backend" do
    assert_raise FunctionClauseError, fn ->
      AgentAdapter.adapter_for("unknown")
    end
  end
end
