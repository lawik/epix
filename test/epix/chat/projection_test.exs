defmodule Epix.Chat.ProjectionTest do
  use ExUnit.Case, async: true

  alias Epix.Chat.Projection

  setup do: %{state: Projection.new()}

  test "new/0 starts empty and idle" do
    assert Projection.new() == %{messages: [], status: :idle, log: []}
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

  test "assistant text appends a message and logs a reply", %{state: state} do
    state = Projection.apply_event(state, {:assistant, %{text: "hi there", tool_calls: []}})
    assert state.messages == [%{role: :assistant, text: "hi there"}]
    assert state.log == ["✎ reply"]
  end

  test "empty assistant text with tool calls logs the wanted tools", %{state: state} do
    event = {:assistant, %{text: "", tool_calls: [%{name: "lua_eval", args: "{}"}]}}
    state = Projection.apply_event(state, event)
    assert state.messages == [%{role: :activity, text: "→ lua_eval"}]
    assert state.log == ["↻ wants tools: lua_eval"]
  end

  test "tool_start and tool_result both log; tool_result also adds a transcript line", %{state: state} do
    state =
      state
      |> Projection.apply_event({:tool_start, %{name: "lua_eval"}})
      |> Projection.apply_event({:tool_result, %{name: "lua_eval", body: "42\nignored"}})

    assert state.messages == [%{role: :activity, text: "✓ lua_eval: 42"}]
    assert state.log == ["⚙ lua_eval…", "✓ lua_eval: 42"]
  end

  test "finish ok marks idle and logs done; finish error records an error", %{state: state} do
    assert Projection.finish(%{state | status: :thinking}, {:ok, "done"}).status == :idle

    state = Projection.finish(state, {:error, :timeout})
    assert state.status == :idle
    assert [%{role: :error, text: "error: :timeout"}] = state.messages
    assert "✗ :timeout" in state.log
  end
end
