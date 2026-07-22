defmodule Epix.SessionTest do
  use ExUnit.Case, async: true

  alias Epix.{Abort, Session}
  alias Epix.Loop.Turn
  alias ReqLLM.{Message, ToolCall}

  defp done_turn,
    do: %Turn{
      message: %Message{role: :assistant, content: []},
      text: "done",
      finish_reason: :stop
    }

  # A model that returns immediately.
  defp instant_model, do: fn _ctx, _cfg, _rctx -> {:ok, done_turn()} end

  # A model that signals it started, then blocks until the run is cancelled.
  defp blocking_model(test_pid) do
    fn _ctx, _cfg, rctx ->
      send(test_pid, :model_running)
      wait_for_cancel(rctx.abort)
    end
  end

  defp wait_for_cancel(abort) do
    if Abort.cancelled?(abort) do
      {:error, :cancelled}
    else
      Process.sleep(5)
      wait_for_cancel(abort)
    end
  end

  defp start(opts) do
    {:ok, session} = Session.start_link([api_key: "test"] ++ opts)
    session
  end

  test "decode_args parses JSON objects and defaults malformed/empty input to %{}" do
    assert Session.decode_args(~s({"x": 1, "y": "z"})) == %{"x" => 1, "y" => "z"}
    assert Session.decode_args("{not json") == %{}
    assert Session.decode_args(nil) == %{}
    assert Session.decode_args("") == %{}
    assert Session.decode_args("[1, 2]") == %{}
  end

  test "a run completes off the call path and updates the context" do
    session = start(model_fun: instant_model())
    assert {:ok, "done"} = Session.run(session, "hi")
    roles = Enum.map(Session.context(session).messages, & &1.role)
    assert roles == [:system, :user, :assistant]
  end

  test "cancel/1 stops an in-flight run; idle cancel reports :idle" do
    session = start(model_fun: blocking_model(self()))
    assert {:error, :idle} = Session.cancel(session)

    task = Task.async(fn -> Session.run(session, "hi") end)
    assert_receive :model_running, 1000

    assert :ok = Session.cancel(session)
    assert {:error, :cancelled} = Task.await(task)
    # After the run, the session is idle again.
    assert {:error, :idle} = Session.cancel(session)
  end

  test "a second run while one is active returns :busy" do
    session = start(model_fun: blocking_model(self()))
    task = Task.async(fn -> Session.run(session, "first") end)
    assert_receive :model_running, 1000

    assert {:error, :busy} = Session.run(session, "second")

    Session.cancel(session)
    assert {:error, :cancelled} = Task.await(task)
  end

  test "context/1 is answerable while a run is in flight (off the call path)" do
    session = start(model_fun: blocking_model(self()))
    task = Task.async(fn -> Session.run(session, "hi") end)
    assert_receive :model_running, 1000

    # The GenServer answers despite the run being in progress (it returns the
    # last committed context; the in-flight prompt commits when the run finishes).
    roles = Enum.map(Session.context(session).messages, & &1.role)
    assert roles == [:system]

    Session.cancel(session)
    Task.await(task)
  end

  test "steer/2 reports :idle when no run is active" do
    session = start(model_fun: instant_model())
    assert {:error, :idle} = Session.steer(session, "hello")
  end

  test "Lua tool calls emit :lua_call and :lua_result around real dispatch" do
    good = tool_call("c1", "lua_eval", ~s({"code":"return 2+2"}))
    bad = tool_call("c2", "lua_eval", ~s({"code":"return ("}))

    turns = [
      %Turn{
        message: %Message{role: :assistant, content: [], tool_calls: [good, bad]},
        tool_calls: [good, bad],
        finish_reason: :tool_calls
      },
      done_turn()
    ]

    {:ok, agent} = Agent.start_link(fn -> turns end)

    scripted = fn _ctx, _cfg, _rctx ->
      {:ok, Agent.get_and_update(agent, fn [t | rest] -> {t, rest} end)}
    end

    test_pid = self()
    # No :tool_fun override, so the session's real sandbox dispatch runs.
    session = start(model_fun: scripted)
    emit = fn event -> send(test_pid, {:event, event}) end

    assert {:ok, "done"} = Session.run(session, "hi", emit: emit)

    assert_receive {:event, {:lua_call, %{tool: "lua_eval", code: "return 2+2"}}}
    assert_receive {:event, {:lua_result, %{code: "return 2+2", result: "4", ok: true}}}

    assert_receive {:event, {:lua_call, %{code: "return ("}}}
    assert_receive {:event, {:lua_result, %{code: "return (", result: "ERROR: " <> _, ok: false}}}
  end

  defp tool_call(id, name, args_json) do
    %ToolCall{id: id, type: "function", function: %{name: name, arguments: args_json}}
  end
end
