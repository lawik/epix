defmodule Epix.Chat.Projection do
  @moduledoc """
  Pure projection of loop events into chat view state.

  Keeping this a pure function (state + event -> state) means the interesting
  logic, how a run turns into a transcript and a stage log, is testable without
  Solve or a model. The Solve controller just calls these in its `handle_info`.

  View state is `%{messages, status, log, tokens, stream}`:

    * `messages` - the conversational transcript: plain `%{role, text}` entries
      plus structured tool entries (`t:tool_entry/0`) that update in place as a
      tool runs. Results are kept whole so a frontend can truncate for display
      and expand on demand; only the `log` truncates.
    * `log` - every internal stage (request, response timing, tool start/finish),
      so a slow model call is visible rather than a frozen `[thinking]`
    * `tokens` - cumulative tokens across responses
    * `stream` - index of the assistant message currently receiving text deltas
      (internal bookkeeping; frontends should read `status`)
  """

  @type role :: :user | :assistant | :error
  @type message :: %{role: role(), text: String.t()} | tool_entry()
  @type tool_entry :: %{
          role: :tool,
          name: String.t(),
          code: String.t() | nil,
          result: String.t() | nil,
          ok: boolean() | nil,
          done: boolean()
        }
  @type status :: :idle | :thinking | :running_tools
  @type state :: %{
          :messages => [message()],
          :status => status(),
          :log => [String.t()],
          :tokens => non_neg_integer(),
          :stream => non_neg_integer() | nil,
          optional(any()) => any()
        }

  @log_limit 200

  @doc "The initial, empty view state."
  @spec new() :: state()
  def new(), do: %{messages: [], status: :idle, log: [], tokens: 0, stream: nil}

  @doc "Records a submitted user prompt and marks the session busy."
  @spec user_prompt(state(), String.t()) :: state()
  def user_prompt(state, text) do
    state
    |> put_status(:thinking)
    |> add_message(%{role: :user, text: text})
    |> add_log("» you: #{first_line(text)}")
  end

  @doc "Records a steering message injected into the in-flight run."
  @spec steer_prompt(state(), String.t()) :: state()
  def steer_prompt(state, text) do
    state
    |> add_message(%{role: :user, text: text})
    |> add_log("↷ steer: #{first_line(text)}")
  end

  @doc "Folds a loop event into the view state."
  @spec apply_event(state(), Epix.Event.t()) :: state()
  def apply_event(state, {:status, status}), do: put_status(state, status)

  def apply_event(state, {:request, %{step: step}}) do
    add_log(state, "→ request · step #{step}")
  end

  def apply_event(state, {:response, %{finish_reason: reason, ms: ms, tokens: tokens}}) do
    state
    |> Map.update!(:tokens, &(&1 + tokens))
    |> add_log("← #{reason} · #{ms}ms · #{tokens}tok")
  end

  # Deltas stream into one assistant message, appended on the first delta and
  # grown in place, so a frontend renders text as it arrives.
  def apply_event(state, {:text_delta, delta}) do
    case state.stream do
      nil ->
        state
        |> Map.put(:stream, length(state.messages))
        |> add_message(%{role: :assistant, text: delta})

      idx ->
        update_message(state, idx, &%{&1 | text: &1.text <> delta})
    end
  end

  def apply_event(state, {:assistant, %{text: text, tool_calls: calls}}) do
    state
    |> finalize_stream(text)
    |> log_assistant(text, calls)
  end

  def apply_event(state, {:tool_start, %{name: name}}) do
    state
    |> add_message(tool_entry(name))
    |> add_log("⚙ #{name}…")
  end

  def apply_event(state, {:lua_call, %{tool: tool, code: code}}) do
    state =
      case find_open_tool(state.messages, tool) do
        nil -> add_message(state, %{tool_entry(tool) | code: code})
        idx -> update_message(state, idx, &%{&1 | code: code})
      end

    add_log(state, "λ #{tool}: #{first_line(code)}")
  end

  def apply_event(state, {:lua_result, %{tool: tool, result: result, ok: ok}}) do
    case find_open_tool(state.messages, tool) do
      nil -> state
      idx -> update_message(state, idx, &%{&1 | result: result, ok: ok})
    end
  end

  def apply_event(state, {:tool_result, %{name: name, body: body}}) do
    {state, ok} = close_tool(state, name, body)
    add_log(state, "#{if ok, do: "✓", else: "✗"} #{name}: #{first_line(body)}")
  end

  def apply_event(state, {:compaction, %{reason: reason, before: before, after: after_tokens}}) do
    add_log(state, "⇆ compaction (#{reason}): #{before} → #{after_tokens} tok")
  end

  def apply_event(state, {:cancelled, %{step: step}}) do
    add_log(state, "✗ cancelled at step #{step}")
  end

  def apply_event(state, {:steering, %{count: count}}),
    do: add_log(state, "↷ steering (#{count})")

  def apply_event(state, {:follow_up, %{count: count}}) do
    add_log(state, "↪ follow-up (#{count})")
  end

  def apply_event(state, {:error, reason}), do: add_log(state, "✗ #{inspect(reason)}")

  def apply_event(state, _event), do: state

  @doc "Marks a run finished, recording an error message on failure."
  @spec finish(state(), Epix.Loop.result()) :: state()
  def finish(state, {:ok, _text}) do
    state |> put_status(:idle) |> Map.put(:stream, nil) |> add_log("■ done")
  end

  def finish(state, {:error, reason}) do
    state
    |> put_status(:idle)
    |> Map.put(:stream, nil)
    |> add_message(%{role: :error, text: "error: #{inspect(reason)}"})
    |> add_log("✗ #{inspect(reason)}")
  end

  # The turn's full text is authoritative over accumulated deltas: a run that
  # streamed gets its message replaced in place, one that did not (or whose
  # deltas were lost) gets the text appended whole.
  defp finalize_stream(%{stream: nil} = state, text) when is_binary(text) and text != "" do
    add_message(state, %{role: :assistant, text: text})
  end

  defp finalize_stream(%{stream: nil} = state, _text), do: state

  defp finalize_stream(%{stream: idx} = state, text) do
    state =
      if is_binary(text) and text != "" do
        update_message(state, idx, &%{&1 | text: text})
      else
        state
      end

    %{state | stream: nil}
  end

  defp tool_entry(name) do
    %{role: :tool, name: name, code: nil, result: nil, ok: nil, done: false}
  end

  # Index of the most recent still-running tool entry for this name.
  defp find_open_tool(messages, name) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {message, idx}, acc ->
      case message do
        %{role: :tool, name: ^name, done: false} -> idx
        _ -> acc
      end
    end)
  end

  defp close_tool(state, name, body) do
    case find_open_tool(state.messages, name) do
      nil ->
        entry = %{tool_entry(name) | result: body, ok: infer_ok(body), done: true}
        {add_message(state, entry), entry.ok}

      idx ->
        entry = Enum.at(state.messages, idx)
        ok = if is_nil(entry.ok), do: infer_ok(body), else: entry.ok
        state = update_message(state, idx, &%{&1 | done: true, result: &1.result || body, ok: ok})
        {state, ok}
    end
  end

  # Dispatch surfaces tool failures to the model as "ERROR: ..." bodies; treat
  # that prefix as failure when no lua_result verdict arrived.
  defp infer_ok(body), do: not String.starts_with?(body, "ERROR:")

  defp log_assistant(state, _text, [_ | _] = calls) do
    add_log(state, "↻ wants tools: " <> Enum.map_join(calls, ", ", & &1.name))
  end

  defp log_assistant(state, text, []) when is_binary(text) and text != "" do
    add_log(state, "✎ reply")
  end

  defp log_assistant(state, _text, _calls), do: state

  defp put_status(state, status), do: %{state | status: status}

  defp add_message(state, message), do: %{state | messages: state.messages ++ [message]}

  defp update_message(state, idx, fun) do
    %{state | messages: List.update_at(state.messages, idx, fun)}
  end

  defp add_log(state, line), do: %{state | log: Enum.take(state.log ++ [line], -@log_limit)}

  defp first_line(body) do
    body |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)
  end
end
