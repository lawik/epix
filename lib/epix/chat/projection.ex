defmodule Epix.Chat.Projection do
  @moduledoc """
  Pure projection of loop events into chat view state.

  Keeping this a pure function (state + event -> state) means the interesting
  logic, how a run turns into a transcript and a stage log, is testable without
  Solve, term_ui, or a model. The Solve controller just calls these in its
  `handle_info`.

  View state is `%{messages: [message], status: status, log: [String.t()]}`:

    * `messages` - the conversational transcript shown in the main pane
    * `log` - every internal stage (request, response timing, tool start/finish),
      shown in the side panel so a slow model call is visible rather than a frozen
      `[thinking]`
  """

  @type role :: :user | :assistant | :activity | :error
  @type message :: %{role: role(), text: String.t()}
  @type status :: :idle | :thinking | :running_tools
  @type state :: %{
          :messages => [message()],
          :status => status(),
          :log => [String.t()],
          optional(any()) => any()
        }

  @log_limit 200

  @doc "The initial, empty view state."
  @spec new() :: state()
  def new(), do: %{messages: [], status: :idle, log: []}

  @doc "Records a submitted user prompt and marks the session busy."
  @spec user_prompt(state(), String.t()) :: state()
  def user_prompt(state, text) do
    state
    |> put_status(:thinking)
    |> add_message(%{role: :user, text: text})
    |> add_log("» you: #{first_line(text)}")
  end

  @doc "Folds a loop event into the view state."
  @spec apply_event(state(), Epix.Event.t()) :: state()
  def apply_event(state, {:status, status}), do: put_status(state, status)

  def apply_event(state, {:request, %{step: step}}) do
    add_log(state, "→ request · step #{step}")
  end

  def apply_event(state, {:response, %{finish_reason: reason, ms: ms, tokens: tokens}}) do
    add_log(state, "← #{reason} · #{ms}ms · #{tokens}tok")
  end

  def apply_event(state, {:assistant, %{text: text, tool_calls: calls}}) do
    state
    |> maybe_append(text)
    |> append_calls(calls)
    |> log_assistant(text, calls)
  end

  def apply_event(state, {:tool_start, %{name: name}}), do: add_log(state, "⚙ #{name}…")

  def apply_event(state, {:tool_result, %{name: name, body: body}}) do
    state
    |> add_message(%{role: :activity, text: "✓ #{name}: #{first_line(body)}"})
    |> add_log("✓ #{name}: #{first_line(body)}")
  end

  def apply_event(state, {:error, reason}), do: add_log(state, "✗ #{inspect(reason)}")

  def apply_event(state, _event), do: state

  @doc "Marks a run finished, recording an error message on failure."
  @spec finish(state(), Epix.Loop.result()) :: state()
  def finish(state, {:ok, _text}) do
    state |> put_status(:idle) |> add_log("■ done")
  end

  def finish(state, {:error, reason}) do
    state
    |> put_status(:idle)
    |> add_message(%{role: :error, text: "error: #{inspect(reason)}"})
    |> add_log("✗ #{inspect(reason)}")
  end

  defp log_assistant(state, _text, [_ | _] = calls) do
    add_log(state, "↻ wants tools: " <> Enum.map_join(calls, ", ", & &1.name))
  end

  defp log_assistant(state, text, []) when is_binary(text) and text != "" do
    add_log(state, "✎ reply")
  end

  defp log_assistant(state, _text, _calls), do: state

  defp maybe_append(state, text) when is_binary(text) and text != "" do
    add_message(state, %{role: :assistant, text: text})
  end

  defp maybe_append(state, _text), do: state

  defp append_calls(state, []), do: state

  defp append_calls(state, calls) do
    add_message(state, %{role: :activity, text: "→ " <> Enum.map_join(calls, ", ", & &1.name)})
  end

  defp put_status(state, status), do: %{state | status: status}

  defp add_message(state, message), do: %{state | messages: state.messages ++ [message]}

  defp add_log(state, line), do: %{state | log: Enum.take(state.log ++ [line], -@log_limit)}

  defp first_line(body) do
    body |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)
  end
end
