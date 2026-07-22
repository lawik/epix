defmodule Epix.TuiTest do
  @moduledoc """
  The TUI is exercised headless: event_to_msg/update/view are pure, and the
  end-to-end tests run a real Chat.App with a fake model, playing the role of
  the TermUI runtime process (init subscribes self(), Solve pushes here).
  """
  use ExUnit.Case, async: true

  alias Epix.Abort
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

  # Signals the test when the model is reached, then blocks until cancelled.
  defp blocking_model(test_pid) do
    fn _ctx, _cfg, rctx ->
      send(test_pid, :model_running)
      wait_cancel(rctx.abort)
    end
  end

  defp wait_cancel(abort) do
    if Abort.cancelled?(abort) do
      {:error, :cancelled}
    else
      Process.sleep(5)
      wait_cancel(abort)
    end
  end

  defp start_state(model_fun) do
    {:ok, app} =
      App.start_link(name: nil, params: %{session_opts: [model_fun: model_fun, api_key: "test"]})

    Tui.init(epix: [chat_app: app])
  end

  # The view is a vertical stack of rows; a row is a text node or a horizontal
  # stack of styled spans. Flatten each row to its visible string.
  defp texts(%RenderNode{type: :stack, children: rows}), do: Enum.map(rows, &row_text/1)

  defp row_text(%RenderNode{type: :text, content: content}), do: content
  defp row_text(%RenderNode{children: children}), do: Enum.map_join(children, "", &row_text/1)

  defp rendered(state), do: state |> Tui.view() |> texts() |> Enum.join("\n")

  defp type(state, string) do
    Enum.reduce(String.graphemes(string), state, fn char, state ->
      {state, []} = Tui.update({:char, char}, state)
      state
    end)
  end

  # Folds pushed Solve updates (as the runtime would) until the predicate holds.
  defp await_until(state, fun, deadline \\ 2_000) do
    if fun.(state) do
      state
    else
      receive do
        %Solve.Message{} = message ->
          await_until(Tui.handle_info(message, state), fun, deadline)
      after
        deadline -> flunk("no Solve update satisfied the predicate")
      end
    end
  end

  describe "event_to_msg/2" do
    test "maps keys to editing, navigation, submit, cancel and quit messages" do
      assert Tui.event_to_msg(%Event.Key{key: "a", modifiers: []}, %{}) == {:msg, {:char, "a"}}
      assert Tui.event_to_msg(%Event.Key{key: :enter}, %{}) == {:msg, :submit}
      assert Tui.event_to_msg(%Event.Key{key: :escape}, %{}) == {:msg, :cancel}
      assert Tui.event_to_msg(%Event.Key{key: :backspace}, %{}) == {:msg, :backspace}
      assert Tui.event_to_msg(%Event.Key{key: :delete}, %{}) == {:msg, :delete}
      assert Tui.event_to_msg(%Event.Key{key: :left}, %{}) == {:msg, {:move, -1}}
      assert Tui.event_to_msg(%Event.Key{key: :right}, %{}) == {:msg, {:move, 1}}
      assert Tui.event_to_msg(%Event.Key{key: :home}, %{}) == {:msg, :cursor_home}
      assert Tui.event_to_msg(%Event.Key{key: :end}, %{}) == {:msg, :cursor_end}
      assert Tui.event_to_msg(%Event.Key{key: :page_up}, %{}) == {:msg, {:scroll, :up}}
      assert Tui.event_to_msg(%Event.Key{key: :page_down}, %{}) == {:msg, {:scroll, :down}}

      assert Tui.event_to_msg(%Event.Key{key: "a", modifiers: [:ctrl]}, %{}) ==
               {:msg, :cursor_home}

      assert Tui.event_to_msg(%Event.Key{key: "e", modifiers: [:ctrl]}, %{}) ==
               {:msg, :cursor_end}

      assert Tui.event_to_msg(%Event.Key{key: "o", modifiers: [:ctrl]}, %{}) ==
               {:msg, :toggle_expand}

      assert Tui.event_to_msg(%Event.Key{key: "c", modifiers: [:ctrl]}, %{}) == {:msg, :quit}
      assert Tui.event_to_msg(%Event.Key{key: "c", modifiers: []}, %{}) == {:msg, {:char, "c"}}
      assert Tui.event_to_msg(%Event.Paste{content: "x"}, %{}) == {:msg, {:paste, "x"}}

      assert Tui.event_to_msg(%Event.Resize{width: 100, height: 40}, %{}) ==
               {:msg, {:resize, 100, 40}}

      assert Tui.event_to_msg(%Event.Key{key: :up}, %{}) == {:msg, {:history, :prev}}
      assert Tui.event_to_msg(%Event.Key{key: :down}, %{}) == {:msg, {:history, :next}}
      assert Tui.event_to_msg(%Event.Key{key: :f1}, %{}) == :ignore
    end
  end

  describe "update/2 editing" do
    setup do
      %{state: start_state(reply_model("unused"))}
    end

    test "cursor editing: move, insert, delete, home and end", %{state: state} do
      state = type(state, "hlo")
      assert %{input: "hlo", cursor: 3} = state

      {state, []} = Tui.update({:move, -2}, state)
      state = type(state, "e")
      assert %{input: "helo", cursor: 2} = state

      {state, []} = Tui.update(:delete, state)
      assert state.input == "heo"

      {state, []} = Tui.update(:cursor_home, state)
      {same, []} = Tui.update(:backspace, state)
      assert same.input == "heo"

      {state, []} = Tui.update(:cursor_end, state)
      {state, []} = Tui.update(:backspace, state)
      assert %{input: "he", cursor: 2} = state

      # Moves clamp at both ends.
      {state, []} = Tui.update({:move, 99}, state)
      assert state.cursor == 2
      {state, []} = Tui.update({:move, -99}, state)
      assert state.cursor == 0
    end

    test "paste inserts at the cursor with newlines flattened", %{state: state} do
      state = type(state, "ad")
      {state, []} = Tui.update({:move, -1}, state)
      {state, []} = Tui.update({:paste, "b\nc"}, state)
      assert %{input: "ab cd", cursor: 4} = state
    end

    test "the cursor block renders at the caret position", %{state: state} do
      state = type(state, "abc")
      {state, []} = Tui.update({:move, -2}, state)
      assert rendered(state) =~ "» a▌bc"
    end

    test "resize stores the new dimensions", %{state: state} do
      {state, []} = Tui.update({:resize, 120, 50}, state)
      assert %{width: 120, height: 50} = state

      # The view emits exactly height rows: transcript + status + input.
      lines = state |> Tui.view() |> texts()
      assert length(lines) == 50
    end

    test "up and down arrows recall submitted history around the draft", %{state: state} do
      state = type(state, "one")
      {state, []} = Tui.update(:submit, state)
      state = type(state, "two")
      {state, []} = Tui.update(:submit, state)

      state = type(state, "dra")

      {state, []} = Tui.update({:history, :prev}, state)
      assert %{input: "two", cursor: 3} = state

      {state, []} = Tui.update({:history, :prev}, state)
      assert state.input == "one"

      # Clamped at the oldest entry.
      {state, []} = Tui.update({:history, :prev}, state)
      assert state.input == "one"

      {state, []} = Tui.update({:history, :next}, state)
      assert state.input == "two"

      # Coming back down restores the stashed draft.
      {state, []} = Tui.update({:history, :next}, state)
      assert %{input: "dra", hist_idx: nil} = state

      # Editing a recalled entry detaches from history browsing.
      {state, []} = Tui.update({:history, :prev}, state)
      state = type(state, "x")
      assert %{input: "twox", hist_idx: nil} = state
    end

    test "submitting the same text twice keeps one history entry", %{state: state} do
      state = type(state, "same")
      {state, []} = Tui.update(:submit, state)
      state = type(state, "same")
      {state, []} = Tui.update(:submit, state)
      assert state.history == ["same"]
    end

    test "blank submits are ignored; quit returns the quit command", %{state: state} do
      state = type(state, " ")
      assert {^state, []} = Tui.update(:submit, state)
      assert {_state, [:quit]} = Tui.update(:quit, state)
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

      out = rendered(type(%{state | chat: chat}, "draft"))

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
      state = type(state, String.duplicate("word ", 10))

      lines = state |> Tui.view() |> texts()
      assert length(lines) == 24
      assert length(Enum.filter(lines, &(&1 =~ "word"))) > 1
      assert List.last(lines) =~ "▌"
    end

    test "assistant messages render as markdown", %{state: state} do
      body = """
      # Title

      Some **bold** text and a [link](https://example.com).

      ```elixir
      def hello, do: :ok
      ```
      """

      chat = %{state.chat | messages: [%{role: :assistant, text: body}]}
      out = rendered(%{state | chat: chat})

      # Markup is consumed, content survives.
      assert out =~ "Title"
      refute out =~ "# Title"
      assert out =~ "bold"
      refute out =~ "**"
      # The link keeps its URL visible for terminal auto-detection.
      assert out =~ "link"
      assert out =~ "https://example.com"
      # Code fences keep their content (highlighted where a lexer exists).
      assert out =~ "def hello"
    end

    test "wide characters wrap early instead of overflowing the row", %{state: state} do
      {state, []} = Tui.update({:resize, 10, 24}, state)
      body = String.duplicate("你好世界", 3)
      chat = %{state.chat | messages: [%{role: :assistant, text: body}]}

      lines = %{state | chat: chat} |> Tui.view() |> texts()

      # Nothing is lost: every character is still present somewhere.
      joined = Enum.join(lines, "")
      for char <- String.graphemes(body), do: assert(joined =~ char)

      # And no row is wider than the terminal in display columns.
      for line <- lines do
        assert TermUI.Renderer.DisplayWidth.string_width(line) <= 10
      end
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

    test "long tool code is capped and Ctrl+O expands it", %{state: state} do
      code = Enum.map_join(1..20, "\n", &"line #{&1}")
      entry = %{role: :tool, name: "t", code: code, result: nil, ok: nil, done: false}
      state = %{state | chat: %{state.chat | messages: [entry]}, height: 60}

      out = rendered(state)
      assert out =~ "line 6"
      refute out =~ "line 7"
      assert out =~ "…"

      {state, []} = Tui.update(:toggle_expand, state)
      out = rendered(state)
      assert out =~ "line 7"
      assert out =~ "line 20"
      assert rendered(state) =~ "≡ full"
    end

    test "page up scrolls back through the transcript; page down returns to live", %{
      state: state
    } do
      {state, []} = Tui.update({:resize, 40, 10}, state)
      messages = for n <- 1..20, do: %{role: :user, text: "message number #{n}"}
      state = %{state | chat: %{state.chat | messages: messages}}

      live = rendered(state)
      assert live =~ "message number 20"
      refute live =~ "message number 1\n"

      {state, []} = Tui.update({:scroll, :up}, state)
      scrolled = rendered(state)
      refute scrolled =~ "message number 20"
      assert scrolled =~ "↑"

      # Scrolling is clamped at the top: the first message becomes visible.
      state =
        Enum.reduce(1..50, state, fn _, state ->
          {state, []} = Tui.update({:scroll, :up}, state)
          state
        end)

      assert rendered(state) =~ "message number 1"

      # Page down all the way re-follows the tail.
      state =
        Enum.reduce(1..60, state, fn _, state ->
          {state, []} = Tui.update({:scroll, :down}, state)
          state
        end)

      assert state.scroll == 0
      assert rendered(state) =~ "message number 20"
    end
  end

  describe "end to end against a real Chat.App" do
    test "submit dispatches, Solve pushes updates, view shows the reply" do
      state = start_state(reply_model("hello back"))
      assert state.chat.status == :idle

      state = type(state, "hi там")
      {state, []} = Tui.update(:submit, state)
      assert %{input: "", cursor: 0} = state

      state =
        await_until(state, fn state ->
          state.chat.status == :idle and
            Enum.any?(state.chat.messages, &(&1.role == :assistant and &1.text == "hello back"))
        end)

      out = rendered(state)
      assert out =~ "» hi там"
      assert out =~ "hello back"
      assert out =~ "ready"
    end

    test "submitting during a run steers it", %{} do
      state = start_state(blocking_model(self()))

      state = type(state, "go")
      {state, []} = Tui.update(:submit, state)
      assert_receive :model_running, 1000

      state = await_until(state, &(&1.chat.status != :idle))

      state = type(state, "also consider this")
      {state, []} = Tui.update(:submit, state)
      assert state.input == ""

      state =
        await_until(state, fn state ->
          Enum.any?(state.chat.messages, &(&1.role == :user and &1.text == "also consider this"))
        end)

      assert Enum.any?(state.chat.log, &(&1 =~ "↷ steer: also consider this"))

      # Clean up: cancel the blocked run and wait for idle.
      {state, []} = Tui.update(:cancel, state)
      await_until(state, &(&1.chat.status == :idle))
    end
  end
end
