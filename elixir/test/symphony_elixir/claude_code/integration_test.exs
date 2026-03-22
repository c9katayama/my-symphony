defmodule SymphonyElixir.ClaudeCode.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  alias SymphonyElixir.ClaudeCode.Adapter

  test "run a simple Claude Code turn" do
    workspace = Path.join(System.tmp_dir!(), "symphony_cc_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, session} =
      Adapter.start_session(workspace,
        config: %{
          command: "claude",
          model: nil,
          additional_flags: [],
          turn_timeout_ms: 60_000
        }
      )

    on_exit(fn -> Adapter.stop_session(session) end)

    case Adapter.run_turn(session, "Write 'hello' to a file called test.txt", %{},
           on_message: fn _ -> :ok end
         ) do
      {:ok, result} ->
        assert is_binary(result.result)
        IO.puts("Claude Code result: #{result.result}")

      {:error, reason} ->
        flunk("Claude Code turn failed: #{inspect(reason)}")
    end
  end
end
