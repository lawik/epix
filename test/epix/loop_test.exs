defmodule Epix.LoopTest do
  @moduledoc """
  The loop is exercised end to end with no provider and no GenServer: a fake
  `model_fun` returns scripted turns, a fake `tool_fun` returns canned bodies.
  This is the offline analogue of Pi's faux-provider suite.
  """
  use ExUnit.Case, async: true

  alias Epix.Abort
  alias Epix.Loop
  alias Epix.Loop.{Config, Turn}
  alias Epix.Runner
  alias ReqLLM.{Context, Message, ToolCall}

  defp tool_call(id, name, args_json) do
    %ToolCall{id: id, type: "function", function: %{name: name, arguments: args_json}}
  end

  defp assistant_with_call(call), do: %Message{role: :assistant, content: [], tool_calls: [call]}
  # The pure loop reads text from the Turn, not the message, so a bare assistant
  # message is enough here.
  defp assistant_msg, do: %Message{role: :assistant, content: []}

  defp init_state(opts \\ []) do
    config = struct(%Config{}, opts)
    Loop.init(Context.new([Context.user("hi")]), config)
  end

  # A model_fun backed by a list of scripted turns, advanced via an Agent.
  defp scripted(turns) do
    {:ok, agent} = Agent.start_link(fn -> turns end)

    fun = fn _context, _config, _rctx ->
      case Agent.get_and_update(agent, fn
             [t | rest] -> {t, rest}
             [] -> {:done, []}
           end) do
        :done -> {:ok, %Turn{message: assistant_msg(), text: "(no more)", finish_reason: :stop}}
        turn -> {:ok, turn}
      end
    end

    {fun, agent}
  end

  describe "pure transitions" do
    test "a turn with no tool calls terminates with the text" do
      state = init_state()
      turn = %Turn{message: assistant_msg(), tool_calls: [], text: "done", finish_reason: :stop}

      state = Loop.apply_turn(state, turn)
      assert state.phase == :done
      assert Loop.result(state) == {:ok, "done"}
    end

    test "a turn with tool calls moves to the tools phase" do
      call = tool_call("c1", "lua_eval", ~s({"code":"return 1"}))

      turn = %Turn{
        message: assistant_with_call(call),
        tool_calls: [call],
        finish_reason: :tool_calls
      }

      state = init_state() |> Loop.apply_turn(turn)
      assert {:run_tools, [^call], _} = Loop.next(state)
    end

    test "tool results advance the step and return to the model phase" do
      call = tool_call("c1", "lua_eval", "{}")

      turn = %Turn{
        message: assistant_with_call(call),
        tool_calls: [call],
        finish_reason: :tool_calls
      }

      state =
        init_state()
        |> Loop.apply_turn(turn)
        |> Loop.apply_tool_results([%{id: "c1", body: "42"}])

      assert state.phase == :model
      assert state.step == 1
      assert {:call_model, _} = Loop.next(state)
    end

    test "apply_error terminates with the reason" do
      state = init_state() |> Loop.apply_error(:boom)
      assert Loop.result(state) == {:error, :boom}
    end

    test "estimate_tokens counts tool-call arguments, not just text content" do
      call = tool_call("c1", "lua_eval", String.duplicate("x", 100))
      # content is [] but the 100-char args + 8-char name must be counted: 108/4 = 27.
      assert Loop.estimate_tokens([assistant_with_call(call)]) == 27
    end
  end

  describe "Runner.run/4 with fakes" do
    test "runs a tool then returns the final answer" do
      call = tool_call("c1", "lua_eval", ~s({"code":"return 2+2"}))

      {model_fun, _} =
        scripted([
          %Turn{
            message: assistant_with_call(call),
            tool_calls: [call],
            finish_reason: :tool_calls
          },
          %Turn{message: assistant_msg(), text: "the answer is 4", finish_reason: :stop}
        ])

      tool_fun = fn c, _rctx -> "RESULT(#{c.function.name})" end

      {result, final} = Runner.run(init_state(), model_fun, tool_fun)

      assert result == {:ok, "the answer is 4"}
      assert final.step == 1
      # system-less context here: user, assistant(call), tool, assistant(text)
      roles = Enum.map(final.context.messages, & &1.role)
      assert roles == [:user, :assistant, :tool, :assistant]
    end

    test "stops at max_steps instead of looping forever" do
      call = tool_call("c1", "lua_eval", "{}")

      always_calls = fn _ctx, _cfg, _rctx ->
        {:ok,
         %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls}}
      end

      tool_fun = fn _c, _rctx -> "again" end
      state = init_state(max_steps: 2)

      {result, final} = Runner.run(state, always_calls, tool_fun)

      assert match?({:ok, _}, result)
      assert final.stop_reason == :max_steps
      assert final.step == 2
    end

    test "emits status, assistant, and tool_result events" do
      call = tool_call("c1", "lua_eval", ~s({"code":"return 2+2"}))

      {model_fun, _} =
        scripted([
          %Turn{
            message: assistant_with_call(call),
            tool_calls: [call],
            finish_reason: :tool_calls
          },
          %Turn{message: assistant_msg(), text: "4", finish_reason: :stop}
        ])

      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      Runner.run(init_state(), model_fun, fn _c, _rctx -> "4" end, emit: emit)
      events = Agent.get(collector, &Enum.reverse/1)

      assert {:status, :thinking} in events
      assert {:status, :running_tools} in events
      assert Enum.any?(events, &match?({:tool_result, %{name: "lua_eval"}}, &1))
      assert Enum.any?(events, &match?({:assistant, %{text: "4"}}, &1))
    end

    test "model_fun emits text deltas through the run context, in order" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      streaming_model = fn _ctx, _cfg, rctx ->
        rctx.emit.({:text_delta, "Hel"})
        rctx.emit.({:text_delta, "lo"})
        {:ok, %Turn{message: assistant_msg(), text: "Hello", finish_reason: :stop}}
      end

      {result, _final} =
        Runner.run(init_state(), streaming_model, fn _c, _r -> "" end, emit: emit)

      events = Agent.get(collector, &Enum.reverse/1)

      assert result == {:ok, "Hello"}
      assert for({:text_delta, t} <- events, do: t) == ["Hel", "lo"]
    end
  end

  describe "cancellation" do
    test "an already-cancelled token halts before the model is ever called" do
      abort = Abort.new()
      Abort.cancel(abort)

      model = fn _ctx, _cfg, _rctx -> flunk("model must not be called when cancelled") end
      {result, final} = Runner.run(init_state(), model, fn _c, _r -> "" end, abort: abort)

      assert result == {:error, :cancelled}
      assert final.error == :cancelled
    end

    test "a model_fun returning {:error, :cancelled} terminates as cancelled" do
      model = fn _ctx, _cfg, _rctx -> {:error, :cancelled} end
      {result, _final} = Runner.run(init_state(), model, fn _c, _r -> "" end)
      assert result == {:error, :cancelled}
    end

    test "cancelling during tool execution halts before the next model call" do
      call = tool_call("c1", "lua_eval", "{}")
      abort = Abort.new()

      model = fn _ctx, _cfg, _rctx ->
        {:ok,
         %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls}}
      end

      # The tool cancels mid-run; the next drive iteration must halt.
      tool = fn _c, rctx ->
        Abort.cancel(rctx.abort)
        "done"
      end

      {result, final} = Runner.run(init_state(), model, tool, abort: abort)

      assert result == {:error, :cancelled}
      assert final.step == 1
    end

    test "cancellation emits a :cancelled event with the step" do
      abort = Abort.new()
      Abort.cancel(abort)
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      Runner.run(init_state(), fn _c, _f, _r -> {:ok, %Turn{}} end, fn _c, _r -> "" end,
        abort: abort,
        emit: emit
      )

      events = Agent.get(collector, &Enum.reverse/1)
      assert {:cancelled, %{step: 0}} in events
    end

    test "a cancel that lands on the run-completing turn still cancels" do
      abort = Abort.new()

      # Simulate the cancel arriving while the final model call is in flight.
      model = fn _ctx, _cfg, rctx ->
        Abort.cancel(rctx.abort)
        {:ok, %Turn{message: assistant_msg(), text: "final answer", finish_reason: :stop}}
      end

      {result, _final} = Runner.run(init_state(), model, fn _c, _r -> "" end, abort: abort)
      assert result == {:error, :cancelled}
    end
  end

  describe "steering and follow-up" do
    defp once(batch) do
      {:ok, q} = Agent.start_link(fn -> [batch] end)

      fn ->
        Agent.get_and_update(q, fn
          [head | tail] -> {head, tail}
          [] -> {[], []}
        end)
      end
    end

    test "steering injects user messages before the model call and emits an event" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      model = fn _ctx, _cfg, _rctx ->
        {:ok, %Turn{message: assistant_msg(), text: "ok", finish_reason: :stop}}
      end

      {result, final} =
        Runner.run(init_state(), model, fn _c, _r -> "" end,
          steering: once(["steer this"]),
          emit: emit
        )

      assert result == {:ok, "ok"}
      # initial "hi" + injected "steer this"
      assert Enum.count(final.context.messages, &(&1.role == :user)) == 2
      assert {:steering, %{count: 1}} in Agent.get(collector, &Enum.reverse/1)
    end

    test "follow-up resumes a completed run and emits an event" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      {model, _} =
        scripted([
          %Turn{message: assistant_msg(), text: "first", finish_reason: :stop},
          %Turn{message: assistant_msg(), text: "second", finish_reason: :stop}
        ])

      {result, final} =
        Runner.run(init_state(), model, fn _c, _r -> "" end,
          follow_up: once(["continue"]),
          emit: emit
        )

      assert result == {:ok, "second"}
      assert Enum.count(final.context.messages, &(&1.role == :user)) == 2
      assert {:follow_up, %{count: 1}} in Agent.get(collector, &Enum.reverse/1)
    end

    test "follow-up is bounded by max_follow_ups (no infinite loop)" do
      always = fn -> ["again"] end

      model = fn _ctx, _cfg, _rctx ->
        {:ok, %Turn{message: assistant_msg(), text: "done", finish_reason: :stop}}
      end

      {result, final} =
        Runner.run(init_state(max_follow_ups: 3), model, fn _c, _r -> "" end, follow_up: always)

      assert result == {:ok, "done"}
      assert final.follow_ups == 3
    end
  end

  describe "compaction" do
    defp msg_text(message) do
      Enum.map_join(message.content, "", fn
        %{text: text} when is_binary(text) -> text
        _ -> ""
      end)
    end

    defp big_state(opts) do
      ctx = Context.new([Context.user(String.duplicate("x", 100))])
      Loop.init(ctx, struct(%Config{}, opts))
    end

    test "proactive compaction replaces the context when over the threshold" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      # ~25 estimated tokens of context, limit = 10 * 0.5 = 5 -> over threshold.
      state = big_state(context_window: 10, compaction_threshold: 0.5)
      compaction = fn _messages -> {:ok, [Context.user("SUMMARY")]} end
      model = fn _ctx, _cfg, _rctx -> {:ok, %Turn{message: assistant_msg(), text: "ok"}} end

      {result, final} =
        Runner.run(state, model, fn _c, _r -> "" end, compaction: compaction, emit: emit)

      assert result == {:ok, "ok"}
      first_user = Enum.find(final.context.messages, &(&1.role == :user))
      assert msg_text(first_user) == "SUMMARY"

      assert Enum.any?(
               Agent.get(collector, &Enum.reverse/1),
               &match?({:compaction, %{reason: :threshold}}, &1)
             )
    end

    test "a context-overflow error triggers compaction and one retry" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      model = fn _ctx, _cfg, _rctx ->
        case Agent.get_and_update(calls, fn n -> {n, n + 1} end) do
          0 -> {:error, :context_overflow}
          _ -> {:ok, %Turn{message: assistant_msg(), text: "recovered", finish_reason: :stop}}
        end
      end

      # A real compaction shrinks the context; big_state (~25 tok) -> ~0 tok.
      compaction = fn _messages -> {:ok, [Context.user("s")]} end

      {result, _final} =
        Runner.run(big_state([]), model, fn _c, _r -> "" end, compaction: compaction, emit: emit)

      assert result == {:ok, "recovered"}

      assert Enum.any?(
               Agent.get(collector, &Enum.reverse/1),
               &match?({:compaction, %{reason: :overflow}}, &1)
             )
    end

    test "an overflow that compaction cannot help surfaces as an error (no infinite retry)" do
      model = fn _ctx, _cfg, _rctx -> {:error, :context_overflow} end
      # compaction returns the messages unchanged -> compacted == state -> give up
      compaction = fn messages -> {:ok, messages} end

      {result, _final} =
        Runner.run(init_state(), model, fn _c, _r -> "" end, compaction: compaction)

      assert result == {:error, :context_overflow}
    end
  end

  describe "tool execution" do
    defp three_calls,
      do: [tool_call("a", "t_a", "{}"), tool_call("b", "t_b", "{}"), tool_call("c", "t_c", "{}")]

    defp three_call_model(calls) do
      {model, _} =
        scripted([
          %Turn{
            message: %Message{role: :assistant, content: [], tool_calls: calls},
            tool_calls: calls,
            finish_reason: :tool_calls
          },
          %Turn{message: assistant_msg(), text: "done", finish_reason: :stop}
        ])

      model
    end

    # Barrier tool: blocks until all `n` tools are concurrently in flight, so the
    # concurrency check is deterministic (no reliance on sleep/overlap timing).
    defp barrier_tool(gauge, n) do
      fn call, _rctx ->
        Agent.update(gauge, fn {c, m} -> {c + 1, max(m, c + 1)} end)
        wait_for(fn -> elem(Agent.get(gauge, & &1), 0) >= n end, 1000)
        Agent.update(gauge, fn {c, m} -> {c - 1, m} end)
        call.function.name
      end
    end

    # No blocking: under sequential execution the gauge can never exceed 1.
    defp serial_tool(gauge) do
      fn call, _rctx ->
        Agent.update(gauge, fn {c, m} -> {c + 1, max(m, c + 1)} end)
        Agent.update(gauge, fn {c, m} -> {c - 1, m} end)
        call.function.name
      end
    end

    defp wait_for(pred, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait_for(pred, deadline)
    end

    defp do_wait_for(pred, deadline) do
      cond do
        pred.() -> :ok
        System.monotonic_time(:millisecond) >= deadline -> :timeout
        true -> Process.sleep(1) && do_wait_for(pred, deadline)
      end
    end

    defp tool_ids(final) do
      final.context.messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.tool_call_id)
    end

    defp tool_bodies(final) do
      final.context.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(&tool_body/1)
    end

    defp tool_body(%{content: content}) when is_binary(content), do: content

    defp tool_body(%{content: content}) when is_list(content) do
      Enum.map_join(content, "", fn
        %{text: text} when is_binary(text) -> text
        text when is_binary(text) -> text
        _ -> ""
      end)
    end

    defp tool_body(_message), do: ""

    test "parallel execution runs tools concurrently, preserving order and pairing" do
      calls = three_calls()
      {:ok, gauge} = Agent.start_link(fn -> {0, 0} end)

      {result, final} =
        Runner.run(
          init_state(tool_execution: :parallel),
          three_call_model(calls),
          barrier_tool(gauge, 3)
        )

      assert result == {:ok, "done"}
      # The barrier forces all three to be concurrent: the max is exactly 3.
      assert elem(Agent.get(gauge, & &1), 1) == 3
      assert tool_bodies(final) == ["t_a", "t_b", "t_c"]
      # One tool message per call id, in source order, paired with the assistant turn.
      assert tool_ids(final) == ["a", "b", "c"]

      roles = Enum.map(final.context.messages, & &1.role)
      assert roles == [:user, :assistant, :tool, :tool, :tool, :assistant]
    end

    test "sequential execution runs one tool at a time, preserving order" do
      calls = three_calls()
      {:ok, gauge} = Agent.start_link(fn -> {0, 0} end)

      {result, final} =
        Runner.run(
          init_state(tool_execution: :sequential),
          three_call_model(calls),
          serial_tool(gauge)
        )

      assert result == {:ok, "done"}
      assert elem(Agent.get(gauge, & &1), 1) == 1
      assert tool_bodies(final) == ["t_a", "t_b", "t_c"]
      assert tool_ids(final) == ["a", "b", "c"]
    end

    test "a raising tool is contained as a tool result, not a crash" do
      tool = fn _call, _rctx -> raise "kaboom" end

      {result, final} =
        Runner.run(
          init_state(tool_execution: :parallel),
          three_call_model([tool_call("c1", "boom", "{}")]),
          tool
        )

      assert result == {:ok, "done"}
      assert [body] = tool_bodies(final)
      assert body =~ "Tool crashed"
    end

    test "cancelling mid-batch skips the remaining tools" do
      c1 = tool_call("c1", "t1", "{}")
      c2 = tool_call("c2", "t2", "{}")
      abort = Abort.new()

      {model, _} =
        scripted([
          %Turn{
            message: %Message{role: :assistant, content: [], tool_calls: [c1, c2]},
            tool_calls: [c1, c2],
            finish_reason: :tool_calls
          },
          %Turn{message: assistant_msg(), text: "done", finish_reason: :stop}
        ])

      tool = fn call, rctx ->
        if call.function.name == "t1", do: Abort.cancel(rctx.abort)
        "ran #{call.function.name}"
      end

      {result, final} =
        Runner.run(init_state(tool_execution: :sequential), model, tool, abort: abort)

      assert result == {:error, :cancelled}
      assert tool_bodies(final) == ["ran t1", "Tool not run: cancelled"]
    end
  end

  describe "per-turn hooks" do
    defp tool_then_done(name) do
      call = tool_call("c1", name, "{}")

      {model, _} =
        scripted([
          %Turn{
            message: assistant_with_call(call),
            tool_calls: [call],
            finish_reason: :tool_calls
          },
          %Turn{message: assistant_msg(), text: "done", finish_reason: :stop}
        ])

      model
    end

    test "transform_context rewrites the model's messages non-destructively" do
      {:ok, seen} = Agent.start_link(fn -> nil end)

      model = fn ctx, _cfg, _rctx ->
        Agent.update(seen, fn _ -> length(ctx.messages) end)
        {:ok, %Turn{message: assistant_msg(), text: "ok", finish_reason: :stop}}
      end

      state =
        Loop.init(Context.new([Context.user("old"), Context.user("new")]), struct(%Config{}, []))

      transform = fn messages -> Enum.take(messages, -1) end

      {result, final} =
        Runner.run(state, model, fn _c, _r -> "" end, transform_context: transform)

      assert result == {:ok, "ok"}
      # model saw only the last message; persisted context keeps both + the reply.
      assert Agent.get(seen, & &1) == 1
      assert length(final.context.messages) == 3
    end

    test "before_tool_call can block a tool" do
      {:ok, ran} = Agent.start_link(fn -> false end)
      tool = fn _c, _r -> Agent.update(ran, fn _ -> true end) && "ran" end

      before = fn call ->
        if call.function.name == "danger", do: {:block, "not allowed"}, else: :ok
      end

      {result, final} =
        Runner.run(init_state(), tool_then_done("danger"), tool, before_tool_call: before)

      assert result == {:ok, "done"}
      assert Agent.get(ran, & &1) == false
      assert tool_bodies(final) == ["Tool blocked: not allowed"]
    end

    test "after_tool_call transforms the tool result" do
      after_hook = fn _call, body -> String.upcase(body) end

      {result, final} =
        Runner.run(init_state(), tool_then_done("echo"), fn _c, _r -> "hello" end,
          after_tool_call: after_hook
        )

      assert result == {:ok, "done"}
      assert tool_bodies(final) == ["HELLO"]
    end

    test "prepare_next_turn runs once between turns" do
      {:ok, count} = Agent.start_link(fn -> 0 end)
      prepare = fn state -> Agent.update(count, &(&1 + 1)) && state end

      {result, _final} =
        Runner.run(init_state(), tool_then_done("t"), fn _c, _r -> "x" end,
          prepare_next_turn: prepare
        )

      assert result == {:ok, "done"}
      assert Agent.get(count, & &1) == 1
    end

    test "before_tool_call returning an invalid value fails closed (blocks)" do
      before = fn _call -> :whoops end

      {result, final} =
        Runner.run(init_state(), tool_then_done("x"), fn _c, _r -> "ran" end,
          before_tool_call: before
        )

      assert result == {:ok, "done"}
      assert [body] = tool_bodies(final)
      assert body =~ "before_tool_call returned"
    end
  end
end
