defmodule SymphonyElixir.ClaudeCode.OutputParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.OutputParser

  describe "parse_result/1" do
    test "parses successful result JSON" do
      json = ~s({"type":"result","session_id":"abc-123","result":"Done","cost_usd":0.05,"duration_ms":12345,"num_turns":3})
      assert {:ok, result} = OutputParser.parse_result(json)
      assert result.session_id == "abc-123"
      assert result.result == "Done"
      assert result.cost_usd == 0.05
    end

    test "parses error result JSON" do
      json = ~s({"type":"error","error":"Something went wrong"})
      assert {:error, "Something went wrong"} = OutputParser.parse_result(json)
    end

    test "handles invalid JSON" do
      assert {:error, _} = OutputParser.parse_result("not json{")
    end
  end

  describe "parse_streaming_line/1" do
    test "parses result line" do
      json = ~s({"type":"result","session_id":"abc-123","result":"Done","cost_usd":0.01,"duration_ms":500,"num_turns":1})
      assert {:result, result} = OutputParser.parse_streaming_line(json)
      assert result.session_id == "abc-123"
    end

    test "parses non-result JSON as message" do
      json = ~s({"type":"assistant","message":"Working..."})
      assert {:message, msg} = OutputParser.parse_streaming_line(json)
      assert msg["message"] == "Working..."
    end

    test "skips non-JSON lines" do
      assert :skip = OutputParser.parse_streaming_line("some log output")
    end
  end
end
