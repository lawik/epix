defmodule Epix.CompactionTest do
  use ExUnit.Case, async: true

  alias Epix.Compaction
  alias ReqLLM.Message

  defp sys, do: %Message{role: :system, content: [%{type: :text, text: "sys"}]}
  defp user(text), do: %Message{role: :user, content: [%{type: :text, text: text}]}
  defp asst(text), do: %Message{role: :assistant, content: [%{type: :text, text: text}]}

  defp asst_call do
    call = %ReqLLM.ToolCall{id: "c", type: "function", function: %{name: "t", arguments: "{}"}}
    %Message{role: :assistant, content: [], tool_calls: [call]}
  end

  defp tool_result,
    do: %Message{role: :tool, content: [%{type: :text, text: "r"}], tool_call_id: "c"}

  defp text(message), do: Enum.map_join(message.content, "", fn %{text: t} -> t end)

  test "summarizes older turns, keeping the system message and the current turn" do
    messages = [sys(), user("u1"), asst("a1"), user("u2")]
    summarizer = fn old -> {:ok, "SUMMARY of #{length(old)}"} end

    assert {:ok, compacted} = Compaction.compact(messages, summarizer)
    assert Enum.map(compacted, & &1.role) == [:system, :user, :user]
    [_system, summary, current] = compacted
    assert text(summary) =~ "SUMMARY of 2"
    assert text(current) == "u2"
  end

  test "the split keeps an assistant tool-call paired with its tool results" do
    rest = [user("u1"), asst_call(), tool_result(), asst("a1"), user("u2")]
    {old, recent} = Compaction.split_at_last_user(rest)

    # The whole earlier turn (incl. the tool-call/result pair) stays in `old`;
    # `recent` starts at the user message, never an orphaned tool result.
    assert Enum.map(old, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Enum.map(recent, & &1.role) == [:user]
  end

  test "with no older turns it returns the messages unchanged and never summarizes" do
    messages = [sys(), user("only")]
    summarizer = fn _old -> flunk("summarizer must not be called") end
    assert {:ok, ^messages} = Compaction.compact(messages, summarizer)
  end

  test "pop_system splits off a leading system message" do
    assert {[%{role: :system}], [%{role: :user}]} = Compaction.pop_system([sys(), user("u")])
    assert {[], [%{role: :user}]} = Compaction.pop_system([user("u")])
  end

  test "split_at_last_user with no user message returns everything as old" do
    assert {[%{role: :assistant}], []} = Compaction.split_at_last_user([asst("a")])
  end

  test "a summarizer error propagates" do
    messages = [sys(), user("u1"), asst("a1"), user("u2")]
    assert {:error, :boom} = Compaction.compact(messages, fn _old -> {:error, :boom} end)
  end

  test "strategy/1 returns a usable compaction function" do
    compaction = Compaction.strategy(fn _old -> {:ok, "S"} end)
    assert {:ok, _} = compaction.([sys(), user("u1"), asst("a1"), user("u2")])
  end
end
