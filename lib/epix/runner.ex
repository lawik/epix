defmodule Epix.Runner do
  @moduledoc """
  The imperative driver for the pure loop.

  Threads `Epix.Loop.State` through the pure transitions while performing the two
  effects the loop needs, supplied as functions so the driver has no hard
  dependency on a provider or a process:

    * `model_fun` - `(context, config, run_ctx) -> {:ok, Turn} | {:error, reason}`
    * `tool_fun` - `(ReqLLM.ToolCall, run_ctx) -> body_text`

  `run_ctx` carries the observability sink (`emit`, an `Epix.Event` callback), the
  cancellation token (`abort`), and the driver's injected hooks (steering,
  follow-up, compaction, and the per-turn hooks). `model_fun`/`tool_fun` use only
  `emit` and `abort`; the hooks are consumed by the driver itself. Injecting the
  effects is what makes the whole loop testable offline: pass a fake `model_fun`
  that returns scripted turns (Pi's faux-provider trick) and a fake `tool_fun`.

  Tool calls run in parallel by default (see `Config.tool_execution`), preserving
  assistant source order; the Session opts into sequential because its Lua tools
  share the sandbox registry.
  """

  alias Epix.{Abort, Event, Loop}

  require Logger

  @type run_ctx :: %{
          emit: Event.emit(),
          abort: Abort.t(),
          steering: (-> [String.t() | list()]),
          follow_up: (-> [String.t() | list()]),
          compaction: ([ReqLLM.Message.t()] -> {:ok, [ReqLLM.Message.t()]} | {:error, term()}),
          transform_context: ([ReqLLM.Message.t()] -> [ReqLLM.Message.t()]),
          before_tool_call: (ReqLLM.ToolCall.t() -> :ok | {:block, String.t()}),
          after_tool_call: (ReqLLM.ToolCall.t(), String.t() -> String.t()),
          prepare_next_turn: (Loop.State.t() -> Loop.State.t())
        }
  @type model_fun :: (ReqLLM.Context.t(), Loop.Config.t(), run_ctx() ->
                        {:ok, Loop.Turn.t()} | {:error, term()})
  @type tool_fun :: (ReqLLM.ToolCall.t(), run_ctx() -> String.t())

  # Compact-and-retry attempts when a model call reports a context overflow.
  @overflow_retries 1

  @doc """
  Runs the loop to termination. Returns `{result, final_state}`.

  Options: `:emit` (`Epix.Event.emit`, default no-op), `:abort` (`Epix.Abort.t`,
  default a fresh token), `:steering` / `:follow_up` (0-arity functions returning
  a list of user-message contents — pulled before each model call and when the
  run would otherwise halt, respectively), `:verbose` (log, default false).
  """
  @spec run(Loop.State.t(), model_fun(), tool_fun(), keyword()) ::
          {Loop.result(), Loop.State.t()}
  def run(%Loop.State{} = state, model_fun, tool_fun, opts \\ []) do
    rctx = %{
      emit: Keyword.get(opts, :emit, Event.noop()),
      abort: Keyword.get(opts, :abort) || Abort.new(),
      steering: Keyword.get(opts, :steering, &no_messages/0),
      follow_up: Keyword.get(opts, :follow_up, &no_messages/0),
      compaction: Keyword.get(opts, :compaction, &default_compaction/1),
      transform_context: Keyword.get(opts, :transform_context, &Function.identity/1),
      before_tool_call: Keyword.get(opts, :before_tool_call, &default_before_tool/1),
      after_tool_call: Keyword.get(opts, :after_tool_call, &default_after_tool/2),
      prepare_next_turn: Keyword.get(opts, :prepare_next_turn, &Function.identity/1)
    }

    drive(state, model_fun, tool_fun, rctx, Keyword.get(opts, :verbose, false))
  end

  defp no_messages(), do: []
  defp default_compaction(messages), do: {:ok, messages}
  defp default_before_tool(_call), do: :ok
  defp default_after_tool(_call, body), do: body

  defp drive(state, model_fun, tool_fun, rctx, verbose) do
    # A set cancellation token wins, even on a run-completing turn (the cancel
    # may land while the final model call is in flight).
    if Abort.cancelled?(rctx.abort) do
      halt_cancelled(state, rctx.emit)
    else
      step(Loop.next(state), model_fun, tool_fun, rctx, verbose, rctx.emit)
    end
  end

  # A normally-completed run can be resumed by follow-up messages, bounded by
  # max_follow_ups so a misbehaving follow-up source cannot loop forever.
  defp step({:halt, {:ok, _} = result, state}, model_fun, tool_fun, rctx, verbose, _emit) do
    case rctx.follow_up.() do
      contents when contents != [] and state.follow_ups < state.config.max_follow_ups ->
        rctx.emit.({:follow_up, %{count: length(contents)}})
        state = %{state | follow_ups: state.follow_ups + 1}
        drive(Loop.inject_user(state, contents), model_fun, tool_fun, rctx, verbose)

      _none_or_capped ->
        {result, state}
    end
  end

  defp step({:halt, result, state}, _model_fun, _tool_fun, _rctx, _verbose, _emit),
    do: {result, state}

  defp step({:call_model, state}, model_fun, tool_fun, rctx, verbose, emit) do
    state = state |> pull_steering(rctx) |> maybe_compact(rctx)
    emit.({:status, :thinking})
    emit.({:request, %{step: state.step}})
    started = System.monotonic_time(:millisecond)

    case call_model(state, model_fun, rctx, @overflow_retries) do
      {:ok, turn, state} ->
        elapsed = System.monotonic_time(:millisecond) - started

        emit.(
          {:response, %{finish_reason: turn.finish_reason, ms: elapsed, tokens: tokens(turn)}}
        )

        emit.({:assistant, summarize(turn)})
        drive(Loop.apply_turn(state, turn), model_fun, tool_fun, rctx, verbose)

      {:cancelled, state} ->
        halt_cancelled(state, emit)

      {:error, reason, state} ->
        emit.({:error, reason})
        drive(Loop.apply_error(state, reason), model_fun, tool_fun, rctx, verbose)
    end
  end

  defp step({:run_tools, calls, state}, model_fun, tool_fun, rctx, verbose, emit) do
    emit.({:status, :running_tools})
    results = run_tools(calls, tool_fun, rctx, verbose, state.config)
    # prepare_next_turn can swap the model/context between turns.
    state = state |> Loop.apply_tool_results(results) |> rctx.prepare_next_turn.()
    drive(state, model_fun, tool_fun, rctx, verbose)
  end

  defp run_tools(calls, tool_fun, rctx, verbose, %{tool_execution: :sequential}) do
    Enum.map(calls, &run_one(&1, tool_fun, rctx, verbose))
  end

  # Parallel by default (like Pi); results stay in assistant source order via
  # `ordered: true`. The Session opts into :sequential for its shared Lua sandbox.
  defp run_tools(calls, tool_fun, rctx, verbose, config) do
    calls
    |> Task.async_stream(&run_one(&1, tool_fun, rctx, verbose),
      ordered: true,
      max_concurrency: config.max_tool_concurrency,
      timeout: :infinity
    )
    |> Enum.zip(calls)
    |> Enum.map(fn
      {{:ok, result}, _call} -> result
      {{:exit, reason}, call} -> %{id: call.id, body: "Tool crashed: #{inspect(reason)}"}
    end)
  end

  defp halt_cancelled(state, emit) do
    emit.({:cancelled, %{step: state.step}})
    cancelled = Loop.cancel(state)
    {Loop.result(cancelled), cancelled}
  end

  defp pull_steering(state, rctx) do
    case rctx.steering.() do
      [] ->
        state

      contents ->
        rctx.emit.({:steering, %{count: length(contents)}})
        Loop.inject_user(state, contents)
    end
  end

  # Proactive compaction: shrink the context before a model call when the
  # estimated size crosses the configured fraction of the context window.
  defp maybe_compact(state, rctx) do
    limit = trunc(state.config.context_window * state.config.compaction_threshold)

    if Loop.estimate_tokens(state.context.messages) > limit do
      compact(state, rctx, :threshold)
    else
      state
    end
  end

  defp compact(state, rctx, reason) do
    before = Loop.estimate_tokens(state.context.messages)

    with {:ok, messages} <- rctx.compaction.(state.context.messages),
         after_tokens = Loop.estimate_tokens(messages),
         true <- after_tokens < before do
      rctx.emit.({:compaction, %{reason: reason, before: before, after: after_tokens}})
      Loop.replace_context(state, messages)
    else
      # Compaction failed or did not shrink the context: keep the original so a
      # genuine overflow surfaces instead of looping or growing.
      _ -> state
    end
  end

  # Call the model, recovering from a context overflow by compacting and retrying.
  # `transform_context` rewrites the messages sent to the model non-destructively;
  # the persisted state.context is unchanged (apply_turn appends to the original).
  defp call_model(state, model_fun, rctx, retries) do
    send_context = %{state.context | messages: rctx.transform_context.(state.context.messages)}

    case model_fun.(send_context, state.config, rctx) do
      {:ok, turn} ->
        {:ok, turn, state}

      {:error, :cancelled} ->
        {:cancelled, state}

      {:error, reason} ->
        compacted =
          if retries > 0 and overflow?(reason), do: compact(state, rctx, :overflow), else: state

        if compacted != state,
          do: call_model(compacted, model_fun, rctx, retries - 1),
          else: {:error, reason, state}
    end
  end

  defp overflow?(:context_overflow), do: true
  defp overflow?(reason) when is_binary(reason), do: overflow_text?(reason)
  defp overflow?(reason), do: overflow_text?(inspect(reason))

  # Require a subject word and a limit word to co-occur, to avoid misclassifying
  # an unrelated error that merely mentions "context" or "tokens".
  defp overflow_text?(text) do
    text = String.downcase(text)
    subject = String.contains?(text, ["context", "prompt", "token"])

    limit =
      String.contains?(text, [
        "too long",
        "too many",
        "maximum",
        "exceed",
        "reduce the length",
        "context_length_exceeded"
      ])

    subject and limit
  end

  defp run_one(call, tool_fun, rctx, verbose) do
    log(verbose, "tool #{call.function.name} #{call.function.arguments}")
    rctx.emit.({:tool_start, %{name: call.function.name}})
    body = execute_tool(call, tool_fun, rctx)
    log(verbose, "  -> #{truncate(body)}")
    rctx.emit.({:tool_result, %{name: call.function.name, body: body}})
    %{id: call.id, body: body}
  end

  # Tool/hook execution is contained: a raise becomes a tool result the model can
  # see rather than crashing the run/Session. Cancellation is honored per tool.
  defp execute_tool(call, tool_fun, rctx) do
    if Abort.cancelled?(rctx.abort) do
      "Tool not run: cancelled"
    else
      rctx.after_tool_call.(call, run_or_block(call, tool_fun, rctx))
    end
  rescue
    exception -> "Tool crashed: #{Exception.message(exception)}"
  catch
    kind, reason -> "Tool crashed: #{inspect({kind, reason})}"
  end

  # before_tool_call must return :ok or {:block, reason}; anything else fails
  # closed (blocks), so a buggy permission hook never silently allows a tool.
  defp run_or_block(call, tool_fun, rctx) do
    case rctx.before_tool_call.(call) do
      :ok -> tool_fun.(call, rctx)
      {:block, reason} -> "Tool blocked: #{reason}"
      other -> "Tool blocked: before_tool_call returned #{inspect(other)}"
    end
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
