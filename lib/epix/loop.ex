defmodule Epix.Loop do
  @moduledoc """
  The pure agent loop core.

  Models the same control flow as Pi's `runLoop`, with all side effects removed:
  call the model, run any tool calls it requests, feed the results back, repeat
  until the model stops calling tools (or `max_steps` is hit). The two load-bearing
  effects in Pi's loop, the model stream and tool execution, are not performed
  here; `next/1` returns a description of the next effect and the caller
  (`Epix.Runner`) performs it and folds the outcome back in via `apply_turn/2`,
  `apply_error/2`, or `apply_tool_results/2`.

  Everything here is a pure function over `Epix.Loop.State`, so the entire loop is
  testable with hand-built turns and no provider.

  Known simplification vs Pi (a deliberate seam, not a dead end): the running
  context is a `ReqLLM.Context` (provider messages) rather than a separate internal
  message type with custom entries. Steering/follow-up injection (`inject_user/2`)
  and parallel tool execution are modeled; the driver supplies their effects.
  """

  alias Epix.Loop.{State, Turn}
  alias ReqLLM.Context

  @type result :: {:ok, String.t() | nil} | {:error, term()}

  @type step ::
          {:call_model, State.t()}
          | {:run_tools, [ReqLLM.ToolCall.t()], State.t()}
          | {:halt, result(), State.t()}

  @doc "Builds the initial loop state from a context and config."
  @spec init(Context.t(), State.t() | Epix.Loop.Config.t()) :: State.t()
  def init(%Context{} = context, config) do
    %State{context: context, config: config}
  end

  @doc "Decides the next step. Pure: inspects state, performs nothing."
  @spec next(State.t()) :: step()
  def next(%State{phase: :model} = state), do: {:call_model, state}
  def next(%State{phase: :tools, pending_calls: calls} = state), do: {:run_tools, calls, state}
  def next(%State{phase: :done} = state), do: {:halt, result(state), state}

  @doc "Folds a completed model turn into the state."
  @spec apply_turn(State.t(), Turn.t()) :: State.t()
  def apply_turn(%State{} = state, %Turn{} = turn) do
    context = Context.append(state.context, turn.message)

    cond do
      turn.tool_calls == [] ->
        %{
          state
          | context: context,
            phase: :done,
            result: turn.text,
            stop_reason: turn.finish_reason
        }

      state.step >= state.config.max_steps ->
        %{
          state
          | context: context,
            phase: :done,
            result: turn.text,
            pending_calls: turn.tool_calls,
            stop_reason: :max_steps
        }

      true ->
        %{
          state
          | context: context,
            phase: :tools,
            pending_calls: turn.tool_calls,
            stop_reason: turn.finish_reason
        }
    end
  end

  @doc "Folds a model error into the state, terminating the run."
  @spec apply_error(State.t(), term()) :: State.t()
  def apply_error(%State{} = state, reason) do
    %{state | phase: :done, error: reason}
  end

  @doc "Terminates the run as cancelled. Result becomes `{:error, :cancelled}`."
  @spec cancel(State.t()) :: State.t()
  def cancel(%State{} = state), do: apply_error(state, :cancelled)

  @doc """
  Appends user messages and (re)enters the model phase.

  Used for steering (inject before the next model call) and follow-up (resume a
  run that would otherwise halt). Each entry is a string or content-part list.
  """
  @spec inject_user(State.t(), [String.t() | list()]) :: State.t()
  def inject_user(%State{} = state, []), do: state

  def inject_user(%State{} = state, contents) when is_list(contents) do
    context = Enum.reduce(contents, state.context, &Context.append(&2, Context.user(&1)))
    %{state | context: context, phase: :model}
  end

  @doc "Replaces the conversation messages (used by compaction)."
  @spec replace_context(State.t(), [ReqLLM.Message.t()]) :: State.t()
  def replace_context(%State{} = state, messages) when is_list(messages) do
    %{state | context: %{state.context | messages: messages}}
  end

  @doc """
  Rough token estimate for a message list (~4 chars/token over text content).

  Good enough to decide when to compact; not a substitute for a real tokenizer.
  """
  @spec estimate_tokens([ReqLLM.Message.t()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    messages |> Enum.reduce(0, fn message, acc -> acc + message_chars(message) end) |> div(4)
  end

  defp message_chars(%{content: content} = message) when is_list(content) do
    text = Enum.reduce(content, 0, fn part, acc -> acc + part_chars(part) end)
    # Tool-call arguments live in the tool_calls field, not content, and are often
    # the largest payload in an agentic context; count them.
    text + tool_call_chars(Map.get(message, :tool_calls))
  end

  defp message_chars(_message), do: 0

  defp part_chars(%{text: text}) when is_binary(text), do: byte_size(text)
  defp part_chars(_part), do: 0

  defp tool_call_chars(calls) when is_list(calls) do
    Enum.reduce(calls, 0, fn call, acc ->
      function = Map.get(call, :function, %{})

      acc + byte_size(to_string(Map.get(function, :arguments, ""))) +
        byte_size(to_string(Map.get(function, :name, "")))
    end)
  end

  defp tool_call_chars(_calls), do: 0

  @doc """
  Folds tool results back into the context and advances the step.

  `results` is a list of `%{id: tool_call_id, body: text}` in call order.
  """
  @spec apply_tool_results(State.t(), [%{id: String.t(), body: String.t()}]) :: State.t()
  def apply_tool_results(%State{} = state, results) when is_list(results) do
    context =
      Enum.reduce(results, state.context, fn %{id: id, body: body}, ctx ->
        Context.append(ctx, Context.tool_result(id, body))
      end)

    %{state | context: context, phase: :model, pending_calls: [], step: state.step + 1}
  end

  @doc "The terminal result of the run, valid once `phase` is `:done`."
  @spec result(State.t()) :: result()
  def result(%State{error: nil, result: result}), do: {:ok, result}
  def result(%State{error: error}), do: {:error, error}
end
