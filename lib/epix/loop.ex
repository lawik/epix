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

  Known simplifications vs Pi (each a deliberate seam, not a dead end):

    * the running context is a `ReqLLM.Context` (provider messages) rather than a
      separate internal message type with custom entries;
    * steering / follow-up message injection is not modeled yet (Pi's outer loop);
    * tool calls are surfaced as a batch for the driver to run sequentially.
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
