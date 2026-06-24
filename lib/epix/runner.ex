defmodule Epix.Runner do
  @moduledoc """
  The imperative driver for the pure loop.

  Threads `Epix.Loop.State` through the pure transitions while performing the two
  effects the loop needs, supplied as functions so the driver has no hard
  dependency on a provider or a process:

    * `model_fun` - `(context, config) -> {:ok, Turn} | {:error, reason}`
    * `tool_fun` - `(ReqLLM.ToolCall) -> body_text`

  Injecting these is what makes the whole loop testable offline: pass a fake
  `model_fun` that returns scripted turns (Pi's faux-provider trick). The real
  effects are assembled in `Epix.Session`.

  Progress is reported through an injected `:emit` function (`Epix.Event`), the
  analogue of Pi's `emit` sink. The default emits nothing. Frontends consume this
  to observe a run; the pure core never emits.

  Tool calls are run sequentially. Pi defaults to parallel execution but forces
  sequential when a tool requires it; our Lua tools mutate shared sandbox state
  (define then run), which is exactly that case, so sequential is the faithful
  choice here.
  """

  alias Epix.{Event, Loop}

  require Logger

  @type model_fun :: (ReqLLM.Context.t(), Loop.Config.t() ->
                        {:ok, Loop.Turn.t()} | {:error, term()})
  @type tool_fun :: (ReqLLM.ToolCall.t() -> String.t())

  @doc """
  Runs the loop to termination. Returns `{result, final_state}`.

  Options: `:emit` (`Epix.Event.emit`, default no-op), `:verbose` (log, default
  false).
  """
  @spec run(Loop.State.t(), model_fun(), tool_fun(), keyword()) ::
          {Loop.result(), Loop.State.t()}
  def run(%Loop.State{} = state, model_fun, tool_fun, opts \\ []) do
    emit = Keyword.get(opts, :emit, Event.noop())
    verbose = Keyword.get(opts, :verbose, false)
    drive(state, model_fun, tool_fun, emit, verbose)
  end

  defp drive(state, model_fun, tool_fun, emit, verbose) do
    case Loop.next(state) do
      {:halt, result, state} ->
        {result, state}

      {:call_model, state} ->
        emit.({:status, :thinking})
        emit.({:request, %{step: state.step}})
        started = System.monotonic_time(:millisecond)

        case model_fun.(state.context, state.config) do
          {:ok, turn} ->
            elapsed = System.monotonic_time(:millisecond) - started
            emit.({:response, %{finish_reason: turn.finish_reason, ms: elapsed, tokens: tokens(turn)}})
            emit.({:assistant, summarize(turn)})
            drive(Loop.apply_turn(state, turn), model_fun, tool_fun, emit, verbose)

          {:error, reason} ->
            emit.({:error, reason})
            drive(Loop.apply_error(state, reason), model_fun, tool_fun, emit, verbose)
        end

      {:run_tools, calls, state} ->
        emit.({:status, :running_tools})
        results = Enum.map(calls, &run_one(&1, tool_fun, emit, verbose))
        drive(Loop.apply_tool_results(state, results), model_fun, tool_fun, emit, verbose)
    end
  end

  defp run_one(call, tool_fun, emit, verbose) do
    log(verbose, "tool #{call.function.name} #{call.function.arguments}")
    emit.({:tool_start, %{name: call.function.name}})
    body = tool_fun.(call)
    log(verbose, "  -> #{truncate(body)}")
    emit.({:tool_result, %{name: call.function.name, body: body}})
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
