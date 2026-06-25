defmodule Epix.Chat.UITest do
  @moduledoc "Covers the pure Elm reducer (update/2) and a view/1 smoke test."
  use ExUnit.Case, async: true

  alias Epix.Chat.UI

  defp state(overrides \\ %{}) do
    base = %{
      input: "",
      messages: [],
      status: :idle,
      log: [],
      ticks: 0,
      scroll: 0,
      width: 80,
      height: 24
    }

    Map.merge(base, overrides)
  end

  defp up(msg, state), do: elem(UI.update(msg, state), 0)

  test "typing and backspace edit the input buffer" do
    s = state() |> then(&up({:char, "h"}, &1)) |> then(&up({:char, "i"}, &1))
    assert s.input == "hi"
    assert up(:backspace, s).input == "h"
    assert up(:backspace, state(%{input: ""})).input == ""
  end

  test "submitting blank input does nothing (no dispatch, unchanged)" do
    s = state(%{input: "   "})
    assert {^s, []} = UI.update(:submit, s)
  end

  test "tick advances only while busy" do
    assert up(:tick, state(%{status: :idle, ticks: 0})).ticks == 0
    assert up(:tick, state(%{status: :thinking, ticks: 0})).ticks == 1
  end

  test "resize updates dimensions" do
    s = up({:resize, 100, 40}, state())
    assert s.width == 100 and s.height == 40
  end

  test "a solve update replaces view data and resets scroll/ticks" do
    exposed = %{messages: [%{role: :user, text: "hi"}], status: :thinking, log: ["x"]}
    s = up({:solve, exposed}, state(%{scroll: 5, ticks: 9}))
    assert s.messages == exposed.messages
    assert s.status == :thinking
    assert s.log == ["x"]
    assert s.scroll == 0 and s.ticks == 0
  end

  test "scroll is clamped to [0, max_scroll]" do
    msgs = for i <- 1..100, do: %{role: :assistant, text: "line #{i}"}
    s = state(%{messages: msgs})

    scrolled = up(:scroll_up, s)
    assert scrolled.scroll > 0

    # Cannot scroll past the bottom.
    assert up(:scroll_down, s).scroll == 0
    assert up(:wheel_down, s).scroll == 0

    # scroll_top clamps to max_scroll and never below a partial scroll.
    assert up(:scroll_top, s).scroll >= scrolled.scroll
    # scroll_bottom returns to follow mode.
    assert up(:scroll_bottom, scrolled).scroll == 0
  end

  test "view/1 renders without crashing for an empty and a populated state" do
    assert UI.view(state())

    populated =
      state(%{
        messages: [
          %{role: :user, text: String.duplicate("x", 300)},
          %{role: :assistant, text: "ok"}
        ],
        log: ["→ request · step 0", "← stop · 10ms · 5tok"],
        status: :thinking,
        ticks: 3
      })

    # A narrow terminal forces wrap/clip_pad through their interesting branches.
    assert UI.view(%{populated | width: 24, height: 10})
  end
end
