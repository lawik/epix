defmodule Epix.Runner do
  @moduledoc """
  The imperative driver for the pure loop.

  Threads `Epix.Loop.State` through the pure transitions while performing the two
  effects the loop needs, supplied as functions so the driver has no hard
  dependency on a provider or a process:

    * `model_fun` - `(context, config, Epix.Runner.Ctx.t()) -> {:ok, Turn} | {:error, reason}`
    * `tool_fun` - `(ReqLLM.ToolCall, Epix.Runner.Ctx.t()) -> body_text`

  The effects receive an `Epix.Runner.Ctx` (just the event sink `emit` and the
  cancellation token `abort`) — a deliberately small contract. The driver's
  extension points live in `Epix.Runner.Hooks` (steering, follow-up, compaction,
  per-turn hooks) and are consumed by the driver itself, never passed to the
  effects. Injecting the effects is what makes the whole loop testable offline:
  pass a fake `model_fun` that returns scripted turns (Pi's faux-provider trick)
  and a fake `tool_fun`.

  Tool calls run in parallel by default (see `Config.tool_execution`), preserving
  assistant source order; the Session opts into sequential because its Lua tools
  share the sandbox registry.
  """

  alias Epix.{Abort, Event, Loop}
  alias Epix.Runner.{Ctx, Hooks, Run}

  require Logger

  @type model_fun :: (ReqLLM.Context.t(), Loop.Config.t(), Ctx.t() ->
                        {:ok, Loop.Turn.t()} | {:error, term()})
  @type tool_fun :: (ReqLLM.ToolCall.t(), Ctx.t() -> String.t())

  # Compact-and-retry attempts when a model call reports a context overflow.
  @overflow_retries 1

  @doc """
  Runs the loop to termination. Returns `{result, final_state}`.

  Options: `:emit` (`Epix.Event.emit`, default no-op), `:abort` (`Epix.Abort.t`,
  default a fresh token), `:verbose` (log, default false), and any
  `Epix.Runner.Hooks` field (`:steering`, `:follow_up`, `:compaction`,
  `:transform_context`, `:before_tool_call`, `:after_tool_call`,
  `:prepare_next_turn`).
  """
  @spec run(Loop.State.t(), model_fun(), tool_fun(), keyword()) ::
          {Loop.result(), Loop.State.t()}
  def run(%Loop.State{} = state, model_fun, tool_fun, opts \\ []) do
    run = %Run{
      model_fun: model_fun,
      tool_fun: tool_fun,
      ctx: %Ctx{
        emit: Keyword.get(opts, :emit, Event.noop()),
        abort: Keyword.get(opts, :abort) || Abort.new()
      },
      hooks: Hooks.from_opts(opts),
      verbose: Keyword.get(opts, :verbose, false)
    }

    drive(state, run)
  end

  defp drive(state, %Run{ctx: ctx} = run) do
    # A set cancellation token wins, even on a run-completing turn (the cancel
    # may land while the final model call is in flight).
    if Abort.cancelled?(ctx.abort) do
      halt_cancelled(state, ctx.emit)
    else
      step(Loop.next(state), run)
    end
  end

  # A normally-completed run can be resumed by follow-up messages, bounded by
  # max_follow_ups so a misbehaving follow-up source cannot loop forever.
  defp step({:halt, {:ok, _} = result, state}, %Run{} = run) do
    case run.hooks.follow_up.() do
      contents when contents != [] and state.follow_ups < state.config.max_follow_ups ->
        run.ctx.emit.({:follow_up, %{count: length(contents)}})
        state = %{state | follow_ups: state.follow_ups + 1}
        drive(Loop.inject_user(state, contents), run)

      _none_or_capped ->
        {result, state}
    end
  end

  defp step({:halt, result, state}, %Run{}), do: {result, state}

  defp step({:call_model, state}, %Run{ctx: ctx} = run) do
    state = state |> pull_steering(run) |> maybe_compact(run)
    ctx.emit.({:status, :thinking})
    ctx.emit.({:request, %{step: state.step}})
    started = System.monotonic_time(:millisecond)

    case call_model(state, run, @overflow_retries) do
      {:ok, turn, state} ->
        elapsed = System.monotonic_time(:millisecond) - started

        ctx.emit.(
          {:response, %{finish_reason: turn.finish_reason, ms: elapsed, tokens: tokens(turn)}}
        )

        ctx.emit.({:assistant, summarize(turn)})
        drive(Loop.apply_turn(state, turn), run)

      {:cancelled, state} ->
        halt_cancelled(state, ctx.emit)

      {:error, reason, state} ->
        ctx.emit.({:error, reason})
        drive(Loop.apply_error(state, reason), run)
    end
  end

  defp step({:run_tools, calls, state}, %Run{} = run) do
    run.ctx.emit.({:status, :running_tools})
    results = run_tools(calls, run, state.config)
    # prepare_next_turn can swap the model/context between turns.
    state = state |> Loop.apply_tool_results(results) |> run.hooks.prepare_next_turn.()
    drive(state, run)
  end

  defp run_tools(calls, %Run{} = run, %{tool_execution: :sequential}) do
    Enum.map(calls, &run_one(&1, run))
  end

  # Parallel by default (like Pi); results stay in assistant source order via
  # `ordered: true`. The Session opts into :sequential for its shared Lua sandbox.
  defp run_tools(calls, %Run{} = run, config) do
    calls
    |> Task.async_stream(&run_one(&1, run),
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

  defp pull_steering(state, %Run{ctx: ctx, hooks: hooks}) do
    case hooks.steering.() do
      [] ->
        state

      contents ->
        ctx.emit.({:steering, %{count: length(contents)}})
        Loop.inject_user(state, contents)
    end
  end

  # Proactive compaction: shrink the context before a model call when the
  # estimated size crosses the configured fraction of the context window.
  defp maybe_compact(state, %Run{} = run) do
    limit = trunc(state.config.context_window * state.config.compaction_threshold)

    if Loop.estimate_tokens(state.context.messages) > limit do
      compact(state, run, :threshold)
    else
      state
    end
  end

  defp compact(state, %Run{ctx: ctx, hooks: hooks}, reason) do
    before = Loop.estimate_tokens(state.context.messages)

    with {:ok, messages} <- hooks.compaction.(state.context.messages),
         after_tokens = Loop.estimate_tokens(messages),
         true <- after_tokens < before do
      ctx.emit.({:compaction, %{reason: reason, before: before, after: after_tokens}})
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
  defp call_model(state, %Run{} = run, retries) do
    messages = run.hooks.transform_context.(state.context.messages)
    send_context = %{state.context | messages: messages}

    case run.model_fun.(send_context, state.config, run.ctx) do
      {:ok, turn} ->
        {:ok, turn, state}

      {:error, :cancelled} ->
        {:cancelled, state}

      {:error, reason} ->
        compacted =
          if retries > 0 and overflow?(reason), do: compact(state, run, :overflow), else: state

        if compacted != state,
          do: call_model(compacted, run, retries - 1),
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

  defp run_one(call, %Run{ctx: ctx} = run) do
    log(run.verbose, "tool #{call.function.name} #{call.function.arguments}")
    ctx.emit.({:tool_start, %{name: call.function.name}})
    body = execute_tool(call, run)
    log(run.verbose, "  -> #{truncate(body)}")
    ctx.emit.({:tool_result, %{name: call.function.name, body: body}})
    %{id: call.id, body: body}
  end

  # Tool/hook execution is contained: a raise becomes a tool result the model can
  # see rather than crashing the run/Session. Cancellation is honored per tool.
  defp execute_tool(call, %Run{ctx: ctx, hooks: hooks} = run) do
    if Abort.cancelled?(ctx.abort) do
      "Tool not run: cancelled"
    else
      hooks.after_tool_call.(call, run_or_block(call, run))
    end
  rescue
    exception -> "Tool crashed: #{Exception.message(exception)}"
  catch
    kind, reason -> "Tool crashed: #{inspect({kind, reason})}"
  end

  # before_tool_call must return :ok or {:block, reason}; anything else fails
  # closed (blocks), so a buggy permission hook never silently allows a tool.
  defp run_or_block(call, %Run{ctx: ctx, hooks: hooks, tool_fun: tool_fun}) do
    case hooks.before_tool_call.(call) do
      :ok -> tool_fun.(call, ctx)
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
