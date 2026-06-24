defmodule Epix.Chat.UI do
  @moduledoc """
  term_ui Elm root: a two-pane chat. Left is the conversation, right is a sidebar
  of internal stages (requests, response timings, tool start/finish, errors).

  term_ui's node renderer is a flow renderer: `box`/`stack` sizes are not enforced
  as hard bounds, so a side-by-side layout with a pinned input cannot rely on flex
  constraints. Instead the view composes the screen as exactly `height` rows of
  pre-padded text: each body row is `left_column │ right_column`, with a fixed
  header on top and the status + input rows pinned at the bottom. That guarantees
  the input never scrolls off.

  Frontend only: it renders what the Solve controller exposes (delivered as
  `{:solve, exposed}` by `Epix.Chat.Bridge`), forwards prompts via `Solve.dispatch`,
  and keeps ephemeral UI state (input buffer, terminal size, scroll offset, tick
  counter for the spinner/elapsed driven by `Epix.Chat.Ticker`).
  """

  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style

  @tick_ms 250
  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @impl true
  def init(_opts) do
    %{input: "", messages: [], status: :idle, log: [], ticks: 0, scroll: 0, width: 80, height: 24}
  end

  @impl true
  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :quit}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, :scroll_up}
  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, :scroll_down}
  def event_to_msg(%Event.Key{key: :home}, _state), do: {:msg, :scroll_top}
  def event_to_msg(%Event.Key{key: :end}, _state), do: {:msg, :scroll_bottom}
  def event_to_msg(%Event.Mouse{action: :scroll_up}, _state), do: {:msg, :wheel_up}
  def event_to_msg(%Event.Mouse{action: :scroll_down}, _state), do: {:msg, :wheel_down}

  def event_to_msg(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:char, char}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:resize, width, height}}

  def event_to_msg(_event, _state), do: :ignore

  @impl true
  def update({:char, char}, state), do: {%{state | input: state.input <> char}, []}
  def update(:backspace, state), do: {%{state | input: drop_last(state.input)}, []}

  def update(:submit, state) do
    case String.trim(state.input) do
      "" ->
        {state, []}

      text ->
        dispatch_submit(text)
        {%{state | input: ""}, []}
    end
  end

  def update({:solve, exposed}, state) do
    {%{
       state
       | messages: exposed.messages,
         status: exposed.status,
         log: exposed.log,
         ticks: 0,
         scroll: 0
     }, []}
  end

  def update(:tick, %{status: :idle} = state), do: {state, []}
  def update(:tick, state), do: {%{state | ticks: state.ticks + 1}, []}

  def update(:scroll_up, state),
    do: {%{state | scroll: min(max_scroll(state), state.scroll + page(state))}, []}

  def update(:scroll_down, state), do: {%{state | scroll: max(0, state.scroll - page(state))}, []}
  def update(:scroll_top, state), do: {%{state | scroll: max_scroll(state)}, []}
  def update(:scroll_bottom, state), do: {%{state | scroll: 0}, []}

  def update(:wheel_up, state),
    do: {%{state | scroll: min(max_scroll(state), state.scroll + 3)}, []}

  def update(:wheel_down, state), do: {%{state | scroll: max(0, state.scroll - 3)}, []}

  def update({:resize, width, height}, state), do: {%{state | width: width, height: height}, []}
  def update(:quit, state), do: {state, [:quit]}
  def update(_msg, state), do: {state, []}

  @impl true
  def view(state) do
    chat_w = chat_width(state)
    panel_w = panel_width(state)
    body_h = body_height(state)

    chat = chat_lines(state, chat_w)
    scroll = min(state.scroll, max(0, length(chat) - body_h))
    visible_chat = chat |> window(body_h, scroll) |> pad_top(body_h, {"", nil})
    visible_panel = state |> panel_lines() |> Enum.take(-body_h) |> pad_top(body_h, "")

    body =
      Enum.map(0..(body_h - 1), fn i ->
        {chat_text, chat_style} = Enum.at(visible_chat, i)
        panel_text = Enum.at(visible_panel, i)

        stack(:horizontal, [
          text(clip_pad(chat_text, chat_w), chat_style),
          text("│", Style.new(fg: :bright_black)),
          text(clip_pad(panel_text, panel_w), Style.new(fg: :bright_black))
        ])
      end)

    stack(:vertical, [header(state)] ++ body ++ [status_line(state), input_line(state)])
  end

  defp header(state) do
    scrolled = if state.scroll > 0, do: "  [scrolled +#{state.scroll}, End to follow]", else: ""

    text(
      clip_pad(
        "Epix — GLM-5.2 @ Berget   (Enter send · Esc quit · PgUp/PgDn scroll)" <> scrolled,
        state.width
      ),
      Style.new(fg: :cyan, attrs: [:bold])
    )
  end

  defp status_line(%{status: :idle} = state),
    do: text(clip_pad("● idle", state.width), Style.new(fg: :green))

  defp status_line(%{status: status, ticks: ticks} = state) do
    spinner = Enum.at(@spinner, rem(ticks, length(@spinner)))
    seconds = div(ticks * @tick_ms, 1000)
    text(clip_pad("#{spinner} #{status} · #{seconds}s", state.width), Style.new(fg: :yellow))
  end

  defp input_line(state),
    do: text(clip_pad("> " <> state.input, state.width), Style.new(fg: :green))

  defp chat_lines(state, width) do
    state.messages
    |> Enum.reduce({[], false}, fn message, {acc, any?} ->
      separator = if any? and message.role == :user, do: [{"", nil}], else: []
      {acc ++ separator ++ message_lines(message, width), true}
    end)
    |> elem(0)
  end

  # Label the role once, on the first line; indent wrapped/continuation lines so
  # the role prefix is not repeated on every line.
  defp message_lines(%{role: role, text: body}, width) do
    style = role_style(role)
    prefix = role_prefix(role)
    indent = String.duplicate(" ", String.length(prefix))
    avail = max(1, width - String.length(prefix))

    pieces = body |> String.split("\n") |> Enum.flat_map(&wrap(&1, avail))
    pieces = if pieces == [], do: [""], else: pieces

    pieces
    |> Enum.with_index()
    |> Enum.map(fn {piece, index} ->
      {if(index == 0, do: prefix, else: indent) <> piece, style}
    end)
  end

  # The sidebar log stays one entry per line (truncated, not wrapped) so it reads
  # as a compact stream.
  defp panel_lines(state), do: Enum.map(state.log, &("· " <> &1))

  # --- geometry ---

  defp panel_width(state),
    do: state.width |> div(3) |> max(16) |> min(40) |> min(max(0, state.width - 12))

  defp chat_width(state), do: max(10, state.width - panel_width(state) - 1)
  defp body_height(state), do: max(3, state.height - 3)
  defp page(state), do: max(1, body_height(state) - 1)

  defp max_scroll(state),
    do: max(0, length(chat_lines(state, chat_width(state))) - body_height(state))

  defp window(lines, body_h, scroll) do
    keep = max(0, length(lines) - scroll)
    lines |> Enum.take(keep) |> Enum.take(-body_h)
  end

  defp pad_top(list, n, fill), do: List.duplicate(fill, max(0, n - length(list))) ++ list

  # --- text ---

  defp wrap(string, width) when width > 0 do
    if String.length(string) <= width do
      [string]
    else
      [
        String.slice(string, 0, width)
        | wrap(String.slice(string, width, String.length(string)), width)
      ]
    end
  end

  defp wrap(string, _width), do: [string]

  defp clip_pad(string, width) when width > 0,
    do: string |> String.slice(0, width) |> String.pad_trailing(width)

  defp clip_pad(string, _width), do: string

  defp drop_last(""), do: ""
  defp drop_last(string), do: String.slice(string, 0, String.length(string) - 1)

  defp role_prefix(:user), do: "you: "
  defp role_prefix(:assistant), do: "ai:  "
  defp role_prefix(:error), do: "!!   "
  defp role_prefix(:activity), do: "     "

  defp role_style(:user), do: Style.new(fg: :white, attrs: [:bold])
  defp role_style(:assistant), do: Style.new(fg: :bright_white)
  defp role_style(:error), do: Style.new(fg: :red)
  defp role_style(:activity), do: Style.new(fg: :bright_black)

  defp dispatch_submit(text) do
    %{app: app, controller: controller} = Application.fetch_env!(:epix, :chat)
    Solve.dispatch(app, controller, :submit, %{text: text})
    :ok
  end
end
