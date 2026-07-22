defmodule Epix.Chat.ProjectionTest do
  use ExUnit.Case, async: true

  alias Epix.Chat.Projection

  setup do: %{state: Projection.new()}

  test "new/0 starts empty and idle" do
    assert Projection.new() == %{messages: [], status: :idle, log: [], tokens: 0, stream: nil}
  end

  test "user_prompt appends a user message, logs it, and marks thinking", %{state: state} do
    state = Projection.user_prompt(state, "hello")
    assert state.status == :thinking
    assert state.messages == [%{role: :user, text: "hello"}]
    assert state.log == ["» you: hello"]
  end

  test "a status event updates status without logging", %{state: state} do
    state = Projection.apply_event(state, {:status, :running_tools})
    assert state.status == :running_tools
    assert state.log == []
  end

  test "request and response events populate the stage log", %{state: state} do
    state =
      state
      |> Projection.apply_event({:request, %{step: 0}})
      |> Projection.apply_event({:response, %{finish_reason: :tool_calls, ms: 1200, tokens: 208}})

    assert state.log == ["→ request · step 0", "← tool_calls · 1200ms · 208tok"]
    assert state.messages == []
  end

  test "response events accumulate tokens", %{state: state} do
    state =
      state
      |> Projection.apply_event({:response, %{finish_reason: :tool_calls, ms: 10, tokens: 150}})
      |> Projection.apply_event({:response, %{finish_reason: :stop, ms: 10, tokens: 42}})

    assert state.tokens == 192
  end

  test "assistant text appends a message and logs a reply", %{state: state} do
    state = Projection.apply_event(state, {:assistant, %{text: "hi there", tool_calls: []}})
    assert state.messages == [%{role: :assistant, text: "hi there"}]
    assert state.log == ["✎ reply"]
  end

  test "text deltas stream into one message; the assistant event is authoritative", %{
    state: state
  } do
    state =
      state
      |> Projection.apply_event({:text_delta, "hel"})
      |> Projection.apply_event({:text_delta, "lo"})

    assert [%{role: :assistant, text: "hello"}] = state.messages

    # The full turn text replaces the accumulated deltas in place.
    state = Projection.apply_event(state, {:assistant, %{text: "hello!", tool_calls: []}})
    assert [%{role: :assistant, text: "hello!"}] = state.messages
    assert state.stream == nil

    # A later turn streams into a fresh message.
    state = Projection.apply_event(state, {:text_delta, "next"})
    assert [_, %{role: :assistant, text: "next"}] = state.messages
  end

  test "empty assistant text with tool calls logs the wanted tools", %{state: state} do
    event = {:assistant, %{text: "", tool_calls: [%{name: "lua_eval", args: "{}"}]}}
    state = Projection.apply_event(state, event)
    assert state.messages == []
    assert state.log == ["↻ wants tools: lua_eval"]
  end

  test "tool_start opens a tool entry; tool_result closes it in place", %{state: state} do
    state = Projection.apply_event(state, {:tool_start, %{name: "lua_eval"}})
    assert [%{role: :tool, name: "lua_eval", done: false, result: nil}] = state.messages

    state = Projection.apply_event(state, {:tool_result, %{name: "lua_eval", body: "42\nrest"}})

    assert [%{role: :tool, name: "lua_eval", done: true, result: "42\nrest", ok: true}] =
             state.messages

    assert state.log == ["⚙ lua_eval…", "✓ lua_eval: 42"]
  end

  test "lua events attach code and verdict to the open tool entry", %{state: state} do
    state =
      state
      |> Projection.apply_event({:tool_start, %{name: "lua_eval"}})
      |> Projection.apply_event({:lua_call, %{tool: "lua_eval", code: "return (\nrest"}})
      |> Projection.apply_event(
        {:lua_result, %{tool: "lua_eval", code: "return (", result: "ERROR: boom", ok: false}}
      )
      |> Projection.apply_event({:tool_result, %{name: "lua_eval", body: "ERROR: boom"}})

    assert [
             %{
               role: :tool,
               name: "lua_eval",
               code: "return (\nrest",
               result: "ERROR: boom",
               ok: false,
               done: true
             }
           ] = state.messages

    assert "λ lua_eval: return (" in state.log
    assert "✗ lua_eval: ERROR: boom" in state.log
  end

  test "a failing body without a lua verdict is inferred from the ERROR prefix", %{state: state} do
    state =
      state
      |> Projection.apply_event({:tool_start, %{name: "kv_get"}})
      |> Projection.apply_event({:tool_result, %{name: "kv_get", body: "ERROR: no namespace"}})

    assert [%{ok: false, done: true}] = state.messages
    assert "✗ kv_get: ERROR: no namespace" in state.log
  end

  test "finish ok marks idle and logs done; finish error records an error", %{state: state} do
    done = Projection.finish(%{state | status: :thinking}, {:ok, "done"})
    assert done.status == :idle
    assert "■ done" in done.log

    state = Projection.finish(state, {:error, :timeout})
    assert state.status == :idle
    assert [%{role: :error, text: "error: :timeout"}] = state.messages
    assert "✗ :timeout" in state.log
  end

  test "compaction, cancellation and steering land in the log", %{state: state} do
    state =
      state
      |> Projection.apply_event({:compaction, %{reason: :threshold, before: 9000, after: 1200}})
      |> Projection.apply_event({:cancelled, %{step: 3}})
      |> Projection.apply_event({:steering, %{count: 2}})
      |> Projection.apply_event({:follow_up, %{count: 1}})

    assert "⇆ compaction (threshold): 9000 → 1200 tok" in state.log
    assert "✗ cancelled at step 3" in state.log
    assert "↷ steering (2)" in state.log
    assert "↪ follow-up (1)" in state.log
    assert state.messages == []
  end

  test "events without an explicit clause are ignored (state unchanged)", %{state: state} do
    for event <- [{:reasoning_delta, "x"}, {:unknown_event, %{}}] do
      assert Projection.apply_event(state, event) == state
    end
  end

  test "the log truncates long bodies but the tool entry keeps the full result", %{state: state} do
    body = String.duplicate("x", 200)

    state =
      state
      |> Projection.apply_event({:tool_start, %{name: "t"}})
      |> Projection.apply_event({:tool_result, %{name: "t", body: body}})

    assert [%{role: :tool, result: ^body}] = state.messages
    # "✓ t: " prefix + 80 sliced chars in the log line
    assert ("✓ t: " <> String.duplicate("x", 80)) in state.log
  end
end
