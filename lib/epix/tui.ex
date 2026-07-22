defmodule Epix.Tui do
  @moduledoc """
  Terminal frontend: a TermUI Elm app rendering the chat controller's state.

  The Solve controller stays the source of truth for the transcript; this
  module holds only view-local state (input draft, terminal size). Solve
  pushes `%Solve.Message{}` updates to the runtime process, which forwards
  them here via `handle_info/2` - the TermUI runtime hands any message it
  does not recognize to the root module.

  Start interactively with `Epix.Tui.run(session_opts: [model: ..., api_key: ...])`.

  Keys: Enter submits, Esc cancels the in-flight run, Ctrl+C quits.
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

    %{app: app, chat: chat, input: "", width: width, height: height}
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
  def event_to_msg(%Event.Key{key: "c", modifiers: mods}, _state) do
    if :ctrl in mods, do: {:msg, :quit}, else: {:msg, {:char, "c"}}
  end

  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :cancel}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}

  def event_to_msg(%Event.Key{key: key, modifiers: []}, _state) when is_binary(key) do
    {:msg, {:char, key}}
  end

  def event_to_msg(%Event.Paste{content: content}, _state), do: {:msg, {:paste, content}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state) do
    {:msg, {:resize, width, height}}
  end

  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update({:char, char}, state), do: {%{state | input: state.input <> char}, []}

  def update({:paste, content}, state) do
    {%{state | input: state.input <> String.replace(content, "\n", " ")}, []}
  end

  def update(:backspace, state) do
    {%{state | input: String.slice(state.input, 0..-2//1)}, []}
  end

  def update(:submit, %{chat: %{status: :idle}} = state) do
    case String.trim(state.input) do
      "" ->
        {state, []}

      text ->
        Solve.dispatch(state.app, :chat, :submit, %{text: text})
        {%{state | input: ""}, []}
    end
  end

  # A run is active: keep the draft; steering lands here later.
  def update(:submit, state), do: {state, []}

  def update(:cancel, state) do
    Solve.dispatch(state.app, :chat, :cancel, %{})
    {state, []}
  end

  def update({:resize, width, height}, state), do: {%{state | width: width, height: height}, []}

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
    input = input_lines(state, width)
    transcript_height = max(height - 1 - length(input), 1)

    lines =
      state.chat.messages
      |> Enum.flat_map(&message_lines(&1, width))
      |> Enum.take(-transcript_height)

    padding = List.duplicate(text(""), transcript_height - length(lines))

    stack(
      :vertical,
      padding ++ lines ++ [status_line(state, width)] ++ input
    )
  end

  # --- transcript ---

  defp message_lines(%{role: :user, text: body}, width) do
    styled_lines("» " <> body, width, @user_style) ++ [text("")]
  end

  defp message_lines(%{role: :assistant, text: body}, width) do
    styled_lines(body, width, nil) ++ [text("")]
  end

  defp message_lines(%{role: :error, text: body}, width) do
    styled_lines(body, width, @fail_style) ++ [text("")]
  end

  defp message_lines(%{role: :tool} = entry, width) do
    header_lines(entry, width) ++
      code_lines(entry.code, width) ++ result_lines(entry, width) ++ [text("")]
  end

  defp header_lines(%{done: false, name: name}, width) do
    styled_lines("⚙ #{name}…", width, @tool_style)
  end

  defp header_lines(%{done: true, name: name, ok: ok}, width) do
    {mark, style} = if ok, do: {"✓", @ok_style}, else: {"✗", @fail_style}
    styled_lines("#{mark} #{name}", width, style)
  end

  defp code_lines(nil, _width), do: []

  defp code_lines(code, width) do
    capped(code, width - 4, @code_cap) |> Enum.map(&text("  │ " <> &1, @dim_style))
  end

  # A running Lua tool may already carry a result via lua_result; show results
  # only once the tool is done to avoid flicker between the two events.
  defp result_lines(%{done: false}, _width), do: []
  defp result_lines(%{result: nil}, _width), do: []

  defp result_lines(%{result: result}, width) do
    capped(result, width - 2, @result_cap) |> Enum.map(&text("  " <> &1, @dim_style))
  end

  # --- chrome ---

  defp status_line(%{chat: chat}, width) do
    left = " #{status_label(chat.status)}"
    right = "#{chat.tokens}tok "
    gap = max(width - String.length(left) - String.length(right), 1)
    text(left <> String.duplicate(" ", gap) <> right, @bar_style)
  end

  defp status_label(:idle), do: "ready"
  defp status_label(:thinking), do: "thinking…"
  defp status_label(:running_tools), do: "running tools…"

  # The draft wraps like any other text (cursor included, so it flows with the
  # words); long drafts show their tail, capped so the transcript keeps room.
  defp input_lines(%{input: input}, width) do
    ("» " <> input <> "▌")
    |> wrap(max(width - 1, 1))
    |> Enum.take(-@input_cap)
    |> Enum.map(&text/1)
  end

  # --- helpers ---

  # Unregistered: the TUI holds the pid, and a second TUI instance must not
  # collide on a global name.
  defp start_app!(opts) do
    {:ok, app} = App.start_link(name: nil, params: %{session_opts: opts[:session_opts] || []})
    app
  end

  defp styled_lines(body, width, style) do
    body |> wrap(width) |> Enum.map(&text(&1, style))
  end

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
    |> Enum.reduce([], fn word, rows ->
      case rows do
        [] ->
          [word]

        [row | rest] ->
          if String.length(row) + 1 + String.length(word) <= width do
            [row <> " " <> word | rest]
          else
            [word, row | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp break_word(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word |> String.graphemes() |> Enum.chunk_every(width) |> Enum.map(&Enum.join/1)
    end
  end
end
