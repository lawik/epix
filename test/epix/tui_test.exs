defmodule Epix.TuiTest do
  @moduledoc """
  The TUI is exercised headless: event_to_msg/update/view are pure, and the
  end-to-end test runs a real Chat.App with a fake model, playing the role of
  the TermUI runtime process (init subscribes self(), Solve pushes here).
  """
  use ExUnit.Case, async: true

  alias Epix.Chat.App
  alias Epix.Loop.Turn
  alias Epix.Tui
  alias TermUI.Component.RenderNode
  alias TermUI.Event

  defp reply_model(text) do
    fn _ctx, _cfg, _rctx ->
      {:ok,
       %Turn{
         message: %ReqLLM.Message{role: :assistant, content: []},
         text: text,
         finish_reason: :stop
       }}
    end
  end

  defp start_state(model_fun) do
    {:ok, app} =
      App.start_link(name: nil, params: %{session_opts: [model_fun: model_fun, api_key: "test"]})

    Tui.init(epix: [chat_app: app])
  end

  defp texts(%RenderNode{type: :text, content: content}), do: [content]
  defp texts(%RenderNode{children: children}), do: Enum.flat_map(children, &texts/1)

  defp rendered(state), do: state |> Tui.view() |> texts() |> Enum.join("\n")

  describe "event_to_msg/2" do
    test "maps keys to editing, submit, cancel and quit messages" do
      assert Tui.event_to_msg(%Event.Key{key: "a", modifiers: []}, %{}) == {:msg, {:char, "a"}}
      assert Tui.event_to_msg(%Event.Key{key: :enter}, %{}) == {:msg, :submit}
      assert Tui.event_to_msg(%Event.Key{key: :escape}, %{}) == {:msg, :cancel}
      assert Tui.event_to_msg(%Event.Key{key: :backspace}, %{}) == {:msg, :backspace}
      assert Tui.event_to_msg(%Event.Key{key: "c", modifiers: [:ctrl]}, %{}) == {:msg, :quit}
      assert Tui.event_to_msg(%Event.Key{key: "c", modifiers: []}, %{}) == {:msg, {:char, "c"}}
      assert Tui.event_to_msg(%Event.Paste{content: "x"}, %{}) == {:msg, {:paste, "x"}}

      assert Tui.event_to_msg(%Event.Resize{width: 100, height: 40}, %{}) ==
               {:msg, {:resize, 100, 40}}

      assert Tui.event_to_msg(%Event.Key{key: :up}, %{}) == :ignore
    end
  end

  describe "update/2 editing" do
    setup do
      %{state: start_state(reply_model("unused"))}
    end

    test "chars, paste and backspace edit the draft", %{state: state} do
      {state, []} = Tui.update({:char, "h"}, state)
      {state, []} = Tui.update({:char, "i"}, state)
      assert state.input == "hi"

      {state, []} = Tui.update({:paste, "there\nfriend"}, state)
      assert state.input == "hithere friend"

      {state, []} = Tui.update(:backspace, state)
      assert state.input == "hithere frien"
    end

    test "resize stores the new dimensions", %{state: state} do
      {state, []} = Tui.update({:resize, 120, 50}, state)
      assert %{width: 120, height: 50} = state

      # The view emits exactly height rows: transcript + status + input.
      lines = state |> Tui.view() |> texts()
      assert length(lines) == 50
    end

    test "blank submits are ignored; quit returns the quit command", %{state: state} do
      {state, []} = Tui.update({:char, " "}, state)
      assert {^state, []} = Tui.update(:submit, state)
      assert {_state, [:quit]} = Tui.update(:quit, state)
    end

    test "submit while a run is active keeps the draft", %{state: state} do
      state = %{state | chat: %{state.chat | status: :thinking}, input: "queued thought"}
      assert {%{input: "queued thought"}, []} = Tui.update(:submit, state)
    end
  end

  describe "view/1" do
    setup do
      %{state: start_state(reply_model("unused"))}
    end

    test "renders transcript roles, status bar and input draft", %{state: state} do
      chat = %{
        state.chat
        | messages: [
            %{role: :user, text: "hello"},
            %{role: :assistant, text: "hi back"},
            %{role: :error, text: "error: :boom"}
          ],
          status: :thinking,
          tokens: 42
      }

      out = rendered(%{state | chat: chat, input: "draft"})

      assert out =~ "» hello"
      assert out =~ "hi back"
      assert out =~ "error: :boom"
      assert out =~ "thinking…"
      assert out =~ "42tok"
      assert out =~ "» draft▌"
    end

    test "tool entries show state, code and result", %{state: state} do
      running = %{
        role: :tool,
        name: "lua_eval",
        code: "return 2+2",
        result: nil,
        ok: nil,
        done: false
      }

      done = %{running | done: true, ok: true, result: "4"}
      failed = %{running | name: "lua_run_tool", done: true, ok: false, result: "ERROR: boom"}

      out = rendered(%{state | chat: %{state.chat | messages: [running]}})
      assert out =~ "⚙ lua_eval…"
      assert out =~ "│ return 2+2"
      # No result until the tool is done.
      refute out =~ "\n  4"

      out = rendered(%{state | chat: %{state.chat | messages: [done]}})
      assert out =~ "✓ lua_eval"
      assert out =~ "  4"

      out = rendered(%{state | chat: %{state.chat | messages: [failed]}})
      assert out =~ "✗ lua_run_tool"
      assert out =~ "ERROR: boom"
    end

    test "transcript text wraps at word boundaries within the width", %{state: state} do
      {state, []} = Tui.update({:resize, 30, 24}, state)

      chat = %{
        state.chat
        | messages: [%{role: :assistant, text: "alpha beta gamma delta epsilon zeta"}]
      }

      lines = %{state | chat: chat} |> Tui.view() |> texts()
      joined = Enum.join(lines, "\n")

      # Intact words: a mid-word break would insert a newline inside the word.
      for word <- ~w(alpha beta gamma delta epsilon zeta), do: assert(joined =~ word)

      content = Enum.filter(lines, &(&1 =~ ~r/alpha|beta|gamma|delta|epsilon|zeta/))
      assert length(content) > 1
      for row <- content, do: assert(String.length(row) <= 30)
    end

    test "a long draft wraps into multiple input rows and keeps the cursor", %{state: state} do
      {state, []} = Tui.update({:resize, 20, 24}, state)
      state = %{state | input: String.duplicate("word ", 10)}

      lines = state |> Tui.view() |> texts()
      assert length(lines) == 24
      assert length(Enum.filter(lines, &(&1 =~ "word"))) > 1
      assert List.last(lines) =~ "▌"
    end

    test "code indentation survives wrapping", %{state: state} do
      entry = %{
        role: :tool,
        name: "t",
        code: "if x then\n  y = 1\nend",
        result: nil,
        ok: nil,
        done: false
      }

      out = rendered(%{state | chat: %{state.chat | messages: [entry]}})
      assert out =~ "│   y = 1"
    end

    test "init reads runtime-provided dimensions" do
      {:ok, app} =
        App.start_link(
          name: nil,
          params: %{session_opts: [model_fun: reply_model("x"), api_key: "test"]}
        )

      state = Tui.init(epix: [chat_app: app], dimensions: {123, 45})
      assert %{width: 123, height: 45} = state
    end

    test "long tool code is capped with an ellipsis", %{state: state} do
      code = Enum.map_join(1..20, "\n", &"line #{&1}")
      entry = %{role: :tool, name: "t", code: code, result: nil, ok: nil, done: false}

      out = rendered(%{state | chat: %{state.chat | messages: [entry]}, height: 60})
      assert out =~ "line 6"
      refute out =~ "line 7"
      assert out =~ "…"
    end
  end

  describe "end to end against a real Chat.App" do
    test "submit dispatches, Solve pushes updates, view shows the reply" do
      state = start_state(reply_model("hello back"))
      assert state.chat.status == :idle

      {state, []} =
        Enum.reduce(String.graphemes("hi там"), {state, []}, fn char, {state, _} ->
          Tui.update({:char, char}, state)
        end)

      {state, []} = Tui.update(:submit, state)
      assert state.input == ""

      state = await_idle_reply(state, "hello back")
      out = rendered(state)
      assert out =~ "» hi там"
      assert out =~ "hello back"
      assert out =~ "ready"
    end

    # Fold pushed Solve updates (as the runtime would) until the reply landed.
    defp await_idle_reply(state, text, deadline \\ 2_000) do
      receive do
        %Solve.Message{} = message ->
          state = Tui.handle_info(message, state)

          if state.chat.status == :idle and
               Enum.any?(state.chat.messages, &(&1.role == :assistant and &1.text == text)) do
            state
          else
            await_idle_reply(state, text, deadline)
          end
      after
        deadline -> flunk("no idle update with the assistant reply arrived")
      end
    end
  end
end
