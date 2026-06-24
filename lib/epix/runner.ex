defmodule Epix.Runner do
  @moduledoc """
  The imperative driver for the pure loop.

  Threads `Epix.Loop.State` through the pure transitions while performing the two
  effects the loop needs, supplied as functions so the driver has no hard
  dependency on a provider or a process:

    * `model_fun` - `(context, config, run_ctx) -> {:ok, Turn} | {:error, reason}`
    * `tool_fun` - `(ReqLLM.ToolCall, run_ctx) -> body_text`

  `run_ctx` is `%{emit: emit_fun, abort: Epix.Abort.t()}`: the observability sink
  (`Epix.Event`) and the cancellation token. Bundling them keeps the effect
  signatures stable as features are added. Injecting the effects is what makes the
  whole loop testable offline: pass a fake `model_fun` that returns scripted turns
  (Pi's faux-provider trick) and a fake `tool_fun`.

  Tool calls are run sequentially. Pi defaults to parallel execution but forces
  sequential when a tool requires it; our Lua tools mutate shared sandbox state
  (define then run), which is exactly that case, so sequential is the faithful
  choice here.
  """

  alias Epix.{Abort, Event, Loop}

  require Logger

  @type run_ctx :: %{emit: Event.emit(), abort: Abort.t()}
  @type model_fun :: (ReqLLM.Context.t(), Loop.Config.t(), run_ctx() ->
                        {:ok, Loop.Turn.t()} | {:error, term()})
  @type tool_fun :: (ReqLLM.ToolCall.t(), run_ctx() -> String.t())

  @doc """
  Runs the loop to termination. Returns `{result, final_state}`.

  Options: `:emit` (`Epix.Event.emit`, default no-op), `:abort` (`Epix.Abort.t`,
  default a fresh token), `:verbose` (log, default false).
  """
  @spec run(Loop.State.t(), model_fun(), tool_fun(), keyword()) ::
          {Loop.result(), Loop.State.t()}
  def run(%Loop.State{} = state, model_fun, tool_fun, opts \\ []) do
    rctx = %{
      emit: Keyword.get(opts, :emit, Event.noop()),
      abort: Keyword.get(opts, :abort) || Abort.new()
    }

    drive(state, model_fun, tool_fun, rctx, Keyword.get(opts, :verbose, false))
  end

  defp drive(state, model_fun, tool_fun, rctx, verbose) do
    # Cancellation requested between steps (e.g. during/after tool execution).
    if state.phase != :done and Abort.cancelled?(rctx.abort) do
      halt_cancelled(state, rctx.emit)
    else
      step(Loop.next(state), model_fun, tool_fun, rctx, verbose, rctx.emit)
    end
  end

  defp step({:halt, result, state}, _model_fun, _tool_fun, _rctx, _verbose, _emit),
    do: {result, state}

  defp step({:call_model, state}, model_fun, tool_fun, rctx, verbose, emit) do
    emit.({:status, :thinking})
    emit.({:request, %{step: state.step}})
    started = System.monotonic_time(:millisecond)

    case model_fun.(state.context, state.config, rctx) do
      {:ok, turn} ->
        elapsed = System.monotonic_time(:millisecond) - started

        emit.(
          {:response, %{finish_reason: turn.finish_reason, ms: elapsed, tokens: tokens(turn)}}
        )

        emit.({:assistant, summarize(turn)})
        drive(Loop.apply_turn(state, turn), model_fun, tool_fun, rctx, verbose)

      {:error, :cancelled} ->
        halt_cancelled(state, emit)

      {:error, reason} ->
        emit.({:error, reason})
        drive(Loop.apply_error(state, reason), model_fun, tool_fun, rctx, verbose)
    end
  end

  defp step({:run_tools, calls, state}, model_fun, tool_fun, rctx, verbose, emit) do
    emit.({:status, :running_tools})
    results = Enum.map(calls, &run_one(&1, tool_fun, rctx, verbose))
    drive(Loop.apply_tool_results(state, results), model_fun, tool_fun, rctx, verbose)
  end

  defp halt_cancelled(state, emit) do
    emit.({:cancelled, %{step: state.step}})
    cancelled = Loop.cancel(state)
    {Loop.result(cancelled), cancelled}
  end

  defp run_one(call, tool_fun, rctx, verbose) do
    log(verbose, "tool #{call.function.name} #{call.function.arguments}")
    rctx.emit.({:tool_start, %{name: call.function.name}})
    body = tool_fun.(call, rctx)
    log(verbose, "  -> #{truncate(body)}")
    rctx.emit.({:tool_result, %{name: call.function.name, body: body}})
    %{id: call.id, body: body}
  end

  defp summarize(turn) do
    calls = Enum.map(turn.tool_calls, &%{name: &1.function.name, args: &1.function.arguments})
    %{text: turn.text, tool_calls: calls}
  end

  defp tokens(%{usage: %{} = usage}), do: Map.get(usage, :total_tokens, 0)
  defp tokens(_turn), do: 0

  defp truncate(text, limit \\ 200) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "...", else: text
  end

  defp log(true, message), do: Logger.info(message)
  defp log(false, _message), do: :ok
end
