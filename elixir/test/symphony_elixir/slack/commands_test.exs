defmodule SymphonyElixir.Slack.CommandsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Slack.Commands

  describe "parse/1" do
    test "parses ticket work command (Japanese)" do
      assert {:work, "MT-123"} = Commands.parse("MT-123 を対応して")
    end

    test "parses ticket work command (English)" do
      assert {:work, "MT-456"} = Commands.parse("work on MT-456")
    end

    test "bare ticket ID defaults to work" do
      assert {:work, "MT-789"} = Commands.parse("MT-789")
    end

    test "parses pause command" do
      assert {:pause, "MT-123"} = Commands.parse("pause MT-123")
    end

    test "parses retry command" do
      assert {:retry, "MT-123"} = Commands.parse("retry MT-123")
    end

    test "parses status command" do
      assert :status = Commands.parse("status")
    end

    test "free text defaults to implement" do
      assert {:implement, "この機能を追加してください"} = Commands.parse("この機能を追加してください")
    end

    test "pause without ticket ID returns nil ticket" do
      assert {:pause, nil} = Commands.parse("pause")
    end

    test "retry without ticket ID returns nil ticket" do
      assert {:retry, nil} = Commands.parse("retry")
    end
  end
end
