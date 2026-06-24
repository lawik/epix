defmodule Epix.LoopTest do
  @moduledoc """
  The loop is exercised end to end with no provider and no GenServer: a fake
  `model_fun` returns scripted turns, a fake `tool_fun` returns canned bodies.
  This is the offline analogue of Pi's faux-provider suite.
  """
  use ExUnit.Case, async: true

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

    fun = fn _context, _config ->
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
      turn = %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls}

      state = init_state() |> Loop.apply_turn(turn)
      assert {:run_tools, [^call], _} = Loop.next(state)
    end

    test "tool results advance the step and return to the model phase" do
      call = tool_call("c1", "lua_eval", "{}")
      turn = %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls}

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
  end

  describe "Runner.run/4 with fakes" do
    test "runs a tool then returns the final answer" do
      call = tool_call("c1", "lua_eval", ~s({"code":"return 2+2"}))

      {model_fun, _} =
        scripted([
          %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls},
          %Turn{message: assistant_msg(), text: "the answer is 4", finish_reason: :stop}
        ])

      tool_fun = fn c -> "RESULT(#{c.function.name})" end

      {result, final} = Runner.run(init_state(), model_fun, tool_fun)

      assert result == {:ok, "the answer is 4"}
      assert final.step == 1
      # system-less context here: user, assistant(call), tool, assistant(text)
      roles = Enum.map(final.context.messages, & &1.role)
      assert roles == [:user, :assistant, :tool, :assistant]
    end

    test "stops at max_steps instead of looping forever" do
      call = tool_call("c1", "lua_eval", "{}")
      always_calls = fn _ctx, _cfg ->
        {:ok, %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls}}
      end

      tool_fun = fn _c -> "again" end
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
          %Turn{message: assistant_with_call(call), tool_calls: [call], finish_reason: :tool_calls},
          %Turn{message: assistant_msg(), text: "4", finish_reason: :stop}
        ])

      {:ok, collector} = Agent.start_link(fn -> [] end)
      emit = fn event -> Agent.update(collector, &[event | &1]) end

      Runner.run(init_state(), model_fun, fn _ -> "4" end, emit: emit)
      events = Agent.get(collector, &Enum.reverse/1)

      assert {:status, :thinking} in events
      assert {:status, :running_tools} in events
      assert Enum.any?(events, &match?({:tool_result, %{name: "lua_eval"}}, &1))
      assert Enum.any?(events, &match?({:assistant, %{text: "4"}}, &1))
    end
  end
end
