defmodule Epix.ModelStreamTest do
  use ExUnit.Case, async: true

  alias Epix.{Abort, ModelStream}
  alias Epix.Loop.Turn
  alias ReqLLM.{Message, Response, StreamResponse}

  defp rctx(abort \\ Abort.new()) do
    parent = self()
    %{emit: fn event -> send(parent, {:emit, event}) end, abort: abort}
  end

  defp chunk(text), do: %ReqLLM.StreamChunk{type: :content, text: text}

  # ReqLLM.Response enforces model/context/id; normalize/1 never reads them.
  defp response(message, finish_reason, usage \\ nil) do
    %Response{
      id: "test",
      model: nil,
      context: nil,
      message: message,
      finish_reason: finish_reason,
      usage: usage
    }
  end

  describe "normalize/1" do
    test "extracts text, tool_calls, finish_reason, and usage" do
      resp =
        response(
          %Message{role: :assistant, content: [%{type: :text, text: "hi"}]},
          :stop,
          %{total_tokens: 5}
        )

      assert %Turn{text: "hi", finish_reason: :stop, usage: %{total_tokens: 5}, tool_calls: []} =
               ModelStream.normalize(resp)
    end

    test "normalizes empty content text to nil (a tool-call-only turn)" do
      call = %ReqLLM.ToolCall{id: "c", type: "function", function: %{name: "t", arguments: "{}"}}
      resp = response(%Message{role: :assistant, content: [], tool_calls: [call]}, :tool_calls)

      turn = ModelStream.normalize(resp)
      assert turn.text == nil
      assert turn.tool_calls == [call]
    end
  end

  describe "emit_chunk/2" do
    test "maps content and thinking chunks to deltas, ignores others" do
      parent = self()
      emit = fn event -> send(parent, {:e, event}) end

      ModelStream.emit_chunk(%{type: :content, text: "a"}, emit)
      assert_received {:e, {:text_delta, "a"}}

      ModelStream.emit_chunk(%{type: :thinking, text: "t"}, emit)
      assert_received {:e, {:reasoning_delta, "t"}}

      ModelStream.emit_chunk(%{type: :meta, info: 1}, emit)
      refute_received {:e, _}
    end
  end

  describe "run/2 (isolated worker)" do
    test "threads an error request through" do
      assert {:error, :boom} = ModelStream.run(fn -> {:error, :boom} end, rctx())
    end

    test "contains a crashing request as {:error, {:model_crashed, _}}" do
      assert {:error, {:model_crashed, _}} = ModelStream.run(fn -> raise "kaboom" end, rctx())
    end

    test "a pre-cancelled run returns :cancelled and calls the stream's cancel" do
      parent = self()

      stream_response = %StreamResponse{
        stream: [chunk("a"), chunk("b")],
        cancel: fn -> send(parent, :cancel_called) end,
        metadata_handle: nil,
        model: nil,
        context: nil
      }

      abort = Abort.new()
      Abort.cancel(abort)

      assert {:error, :cancelled} = ModelStream.run(fn -> {:ok, stream_response} end, rctx(abort))
      assert_received :cancel_called
    end

    test "leaves no {:model_done} message in the caller mailbox" do
      ModelStream.run(fn -> {:error, :done} end, rctx())
      refute_received {:model_done, _, _}
    end
  end
end
