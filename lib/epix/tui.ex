defmodule Epix.Tui do
  @moduledoc """
  Terminal frontend: a TermUI Elm app rendering the chat controller's state.

  The Solve controller stays the source of truth for the transcript; this
  module holds only view-local state (input draft and cursor, scroll offset,
  terminal size). Solve pushes `%Solve.Message{}` updates to the runtime
  process, which forwards them here via `handle_info/2` - the TermUI runtime
  hands any message it does not recognize to the root module.

  Start interactively with `Epix.Tui.run(session_opts: Epix.Model.from_env())`.

  Keys: Enter submits (steers the run when one is active), Esc cancels the
  in-flight run, Ctrl+C quits. Arrows/Home/End (or Ctrl+A/Ctrl+E) edit the
  draft, PageUp/PageDown scroll the transcript (PageDown to the bottom resumes
  following), Ctrl+O toggles full tool code/output.
  """

  use TermUI.Elm

  alias Epix.Chat.App
  alias TermUI.Event
  alias TermUI.Renderer.Style

  @user_style Style.new(fg: :cyan, attrs: [:bold])
  @dim_style Style.new(fg: :bright_black)
  @tool_style Style.new(fg: :yellow)
  @ok_style Style.new(fg: :green)
  @fail_style Style.new(fg: :red)
  @bar_style Style.new(fg: :black, bg: :white)

  @code_cap 6
  @result_cap 3
  @input_cap 5

  @doc """
  Runs the TUI, blocking until quit. Starts its own `Epix.Chat.App` with
  `opts[:session_opts]` unless a running app is given as `opts[:chat_app]`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    TermUI.Runtime.run(root: __MODULE__, epix: opts)
  end

  @impl TermUI.Elm
  def init(opts) do
    epix_opts = Keyword.get(opts, :epix, [])
    app = epix_opts[:chat_app] || start_app!(epix_opts)
    chat = Solve.subscribe(app, :chat, self())
    {width, height} = initial_dimensions(opts)

    %{
      app: app,
      chat: chat,
      input: "",
      cursor: 0,
      scroll: 0,
      expanded: false,
      width: width,
      height: height
    }
  end

  # The runtime passes :dimensions on newer term_ui; fall back to asking the
  # tty directly, and to 80x24 when there is no terminal (tests, pipes).
  defp initial_dimensions(opts) do
    case Keyword.get(opts, :dimensions) do
      {width, height} when is_integer(width) and is_integer(height) ->
        {width, height}

      _ ->
        with {:ok, width} <- :io.columns(), {:ok, height} <- :io.rows() do
          {width, height}
        else
          _ -> {80, 24}
        end
    end
  end

  @impl TermUI.Elm
  def event_to_msg(%Event.Key{key: key, modifiers: mods}, _state) do
    case key_msg(key, :ctrl in mods, mods) do
      nil -> :ignore
      msg -> {:msg, msg}
    end
  end

  def event_to_msg(%Event.Paste{content: content}, _state), do: {:msg, {:paste, content}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state) do
    {:msg, {:resize, width, height}}
  end

  def event_to_msg(_event, _state), do: :ignore

  defp key_msg("c", true, _mods), do: :quit
  defp key_msg("a", true, _mods), do: :cursor_home
  defp key_msg("e", true, _mods), do: :cursor_end
  defp key_msg("o", true, _mods), do: :toggle_expand
  defp key_msg(:enter, _ctrl, _mods), do: :submit
  defp key_msg(:escape, _ctrl, _mods), do: :cancel
  defp key_msg(:backspace, _ctrl, _mods), do: :backspace
  defp key_msg(:delete, _ctrl, _mods), do: :delete
  defp key_msg(:left, _ctrl, _mods), do: {:move, -1}
  defp key_msg(:right, _ctrl, _mods), do: {:move, 1}
  defp key_msg(:home, _ctrl, _mods), do: :cursor_home
  defp key_msg(:end, _ctrl, _mods), do: :cursor_end
  defp key_msg(:page_up, _ctrl, _mods), do: {:scroll, :up}
  defp key_msg(:page_down, _ctrl, _mods), do: {:scroll, :down}
  defp key_msg(key, false, []) when is_binary(key), do: {:char, key}
  defp key_msg(_key, _ctrl, _mods), do: nil

  @impl TermUI.Elm
  def update({:char, char}, state), do: {insert(state, char), []}

  def update({:paste, content}, state) do
    {insert(state, String.replace(content, "\n", " ")), []}
  end

  def update(:backspace, %{cursor: 0} = state), do: {state, []}

  def update(:backspace, state) do
    {before, aft} = split_input(state)
    input = Enum.join(Enum.drop(before, -1)) <> Enum.join(aft)
    {%{state | input: input, cursor: state.cursor - 1}, []}
  end

  def update(:delete, state) do
    {before, aft} = split_input(state)

    case aft do
      [] -> {state, []}
      [_ | rest] -> {%{state | input: Enum.join(before) <> Enum.join(rest)}, []}
    end
  end

  def update({:move, delta}, state) do
    {%{state | cursor: clamp(state.cursor + delta, 0, String.length(state.input))}, []}
  end

  def update(:cursor_home, state), do: {%{state | cursor: 0}, []}
  def update(:cursor_end, state), do: {%{state | cursor: String.length(state.input)}, []}

  def update({:scroll, direction}, state) do
    page = max(div(state.height, 2), 1)
    delta = if direction == :up, do: page, else: -page
    {%{state | scroll: clamp(state.scroll + delta, 0, max_scroll(state))}, []}
  end

  def update(:toggle_expand, state), do: {%{state | expanded: not state.expanded}, []}

  def update(:submit, state) do
    case String.trim(state.input) do
      "" ->
        {state, []}

      text ->
        # An idle session gets a new run; an active one is steered.
        event = if state.chat.status == :idle, do: :submit, else: :steer
        Solve.dispatch(state.app, :chat, event, %{text: text})
        {%{state | input: "", cursor: 0, scroll: 0}, []}
    end
  end

  def update(:cancel, state) do
    Solve.dispatch(state.app, :chat, :cancel, %{})
    {state, []}
  end

  def update({:resize, width, height}, state) do
    state = %{state | width: width, height: height}
    {%{state | scroll: clamp(state.scroll, 0, max_scroll(state))}, []}
  end

  def update(:quit, state), do: {state, [:quit]}

  def update(_msg, state), do: {state, []}

  @doc false
  # Solve pushes exposed-state updates to the runtime process; the runtime
  # forwards them here. Everything else (EXITs, stray messages) is ignored.
  @spec handle_info(term(), map()) :: map()
  def handle_info(
        %Solve.Message{type: :update, payload: %Solve.Update{exposed_state: chat}},
        state
      ) do
    %{state | chat: chat}
  end

  def handle_info(_message, state), do: state

  @impl TermUI.Elm
  def view(%{width: width, height: height} = state) do
    input = input_rows(state, width)
    transcript_height = max(height - 1 - length(input), 1)

    visible =
      state
      |> transcript_rows(width)
      |> Enum.drop(-state.scroll)
      |> Enum.take(-transcript_height)

    padding = List.duplicate({"", nil}, transcript_height - length(visible))

    rows =
      padding ++
        visible ++ [status_row(state, width)] ++ Enum.map(input, &{&1, nil})

    stack(:vertical, Enum.map(rows, fn {content, style} -> text(content, style) end))
  end

  # --- transcript ---

  defp transcript_rows(state, width) do
    Enum.flat_map(state.chat.messages, &message_rows(&1, width, state.expanded))
  end

  defp message_rows(%{role: :user, text: body}, width, _expanded) do
    rows("» " <> body, width, @user_style) ++ [{"", nil}]
  end

  defp message_rows(%{role: :assistant, text: body}, width, _expanded) do
    rows(body, width, nil) ++ [{"", nil}]
  end

  defp message_rows(%{role: :error, text: body}, width, _expanded) do
    rows(body, width, @fail_style) ++ [{"", nil}]
  end

  defp message_rows(%{role: :tool} = entry, width, expanded) do
    header_rows(entry, width) ++
      code_rows(entry.code, width, expanded) ++
      result_rows(entry, width, expanded) ++ [{"", nil}]
  end

  defp header_rows(%{done: false, name: name}, width) do
    rows("⚙ #{name}…", width, @tool_style)
  end

  defp header_rows(%{done: true, name: name, ok: ok}, width) do
    {mark, style} = if ok, do: {"✓", @ok_style}, else: {"✗", @fail_style}
    rows("#{mark} #{name}", width, style)
  end

  defp code_rows(nil, _width, _expanded), do: []

  defp code_rows(code, width, expanded) do
    code
    |> capped(width - 4, if(expanded, do: :all, else: @code_cap))
    |> Enum.map(&{"  │ " <> &1, @dim_style})
  end

  # A running Lua tool may already carry a result via lua_result; show results
  # only once the tool is done to avoid flicker between the two events.
  defp result_rows(%{done: false}, _width, _expanded), do: []
  defp result_rows(%{result: nil}, _width, _expanded), do: []

  defp result_rows(%{result: result}, width, expanded) do
    result
    |> capped(width - 2, if(expanded, do: :all, else: @result_cap))
    |> Enum.map(&{"  " <> &1, @dim_style})
  end

  # --- chrome ---

  defp status_row(%{chat: chat} = state, width) do
    left = " #{status_label(chat.status)}"

    right =
      [
        if(state.expanded, do: "≡ full", else: nil),
        if(state.scroll > 0, do: "↑#{state.scroll}", else: nil),
        "#{chat.tokens}tok "
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    gap = max(width - String.length(left) - String.length(right), 1)
    {left <> String.duplicate(" ", gap) <> right, @bar_style}
  end

  defp status_label(:idle), do: "ready"
  defp status_label(:thinking), do: "thinking…"
  defp status_label(:running_tools), do: "running tools…"

  # The draft wraps like any other text; the cursor block sits at the caret so
  # editing position is visible. Long drafts show their tail, capped so the
  # transcript keeps room.
  defp input_rows(state, width) do
    {before, aft} = split_input(state)

    ("» " <> Enum.join(before) <> "▌" <> Enum.join(aft))
    |> wrap(max(width - 1, 1))
    |> Enum.take(-@input_cap)
  end

  # --- helpers ---

  # Unregistered: the TUI holds the pid, and a second TUI instance must not
  # collide on a global name.
  defp start_app!(opts) do
    {:ok, app} = App.start_link(name: nil, params: %{session_opts: opts[:session_opts] || []})
    app
  end

  defp insert(state, text) do
    {before, aft} = split_input(state)
    input = Enum.join(before) <> text <> Enum.join(aft)
    %{state | input: input, cursor: state.cursor + String.length(text)}
  end

  defp split_input(%{input: input, cursor: cursor}) do
    input |> String.graphemes() |> Enum.split(cursor)
  end

  defp max_scroll(%{width: width, height: height} = state) do
    input_height = length(input_rows(state, width))
    transcript_height = max(height - 1 - input_height, 1)
    max(length(transcript_rows(state, width)) - transcript_height, 0)
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp rows(body, width, style) do
    body |> wrap(width) |> Enum.map(&{&1, style})
  end

  defp capped(body, width, :all), do: wrap(body, width)

  defp capped(body, width, cap) do
    lines = wrap(body, width)

    case Enum.split(lines, cap) do
      {shown, []} -> shown
      {shown, _rest} -> shown ++ ["…"]
    end
  end

  # Word-wraps to the terminal width, splitting embedded newlines first. Each
  # returned line is a single render row; the renderer does not wrap. Splitting
  # and rejoining on single spaces preserves runs of spaces (code indentation);
  # only words longer than the width are hard-broken.
  defp wrap(body, width) when width < 1, do: wrap(body, 1)

  defp wrap(body, width) do
    body
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> String.split(" ")
    |> Enum.flat_map(&break_word(&1, width))
    |> Enum.reduce([], &add_word(&2, &1, width))
    |> Enum.reverse()
  end

  defp add_word([], word, _width), do: [word]

  defp add_word([row | rest], word, width) do
    if String.length(row) + 1 + String.length(word) <= width do
      [row <> " " <> word | rest]
    else
      [word, row | rest]
    end
  end

  defp break_word(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word |> String.graphemes() |> Enum.chunk_every(width) |> Enum.map(&Enum.join/1)
    end
  end
end
