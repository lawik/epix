defmodule Epix.CommandsTest do
  use ExUnit.Case, async: true

  alias Epix.{Abort, Commands, Session}
  alias Epix.Loop.Turn
  alias ReqLLM.Message

  defp done_turn,
    do: %Turn{
      message: %Message{role: :assistant, content: []},
      text: "done",
      finish_reason: :stop
    }

  defp instant_model, do: fn _ctx, _cfg, _rctx -> {:ok, done_turn()} end

  defp blocking_model(test_pid) do
    fn _ctx, _cfg, rctx ->
      send(test_pid, :running)
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

  defp start(opts \\ []) do
    {:ok, session} = Session.start_link(Keyword.put_new(opts, :model_fun, instant_model()))
    session
  end

  test "specs/0 lists the available commands" do
    names = Commands.specs() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["cancel", "history", "reset", "set_namespaces", "status", "steer"]
  end

  test "an unknown command is reported" do
    assert {:error, message} = Commands.dispatch(start(), "nope", %{})
    assert message =~ "unknown command"
  end

  test "status reports an idle session's state" do
    status_session = start(namespaces: ["a"])
    assert {:ok, status} = Commands.dispatch(status_session, "status", %{})
    assert status.running == false
    assert status.namespaces == ["a"]
    assert status.messages == 1
  end

  test "history returns the conversation, reset clears it" do
    session = start()
    assert {:ok, _} = Session.run(session, "hello")

    assert {:ok, %{messages: messages}} = Commands.dispatch(session, "history", %{})
    assert Enum.map(messages, & &1.role) == [:system, :user, :assistant]
    assert Enum.any?(messages, &(&1.role == :user and &1.text == "hello"))

    assert {:ok, %{reset: true}} = Commands.dispatch(session, "reset", %{})
    assert {:ok, %{messages: [%{role: :system}]}} = Commands.dispatch(session, "history", %{})
  end

  test "set_namespaces changes access and is reflected in status" do
    session = start(namespaces: ["a"])

    assert {:ok, %{namespaces: ["x", "y"]}} =
             Commands.dispatch(session, "set_namespaces", %{"namespaces" => ["x", "y"]})

    assert {:ok, %{namespaces: ["x", "y"]}} = Commands.dispatch(session, "status", %{})
  end

  test "cancel/steer report when there is no run; their args are validated" do
    session = start()
    assert {:error, message} = Commands.dispatch(session, "cancel", %{})
    assert message =~ "no run"
    assert {:error, _} = Commands.dispatch(session, "steer", %{"message" => "hi"})

    assert {:error, _} = Commands.dispatch(session, "steer", %{})
    assert {:error, _} = Commands.dispatch(session, "set_namespaces", %{})
  end

  test "cancel aborts an in-flight run" do
    session = start(model_fun: blocking_model(self()))
    task = Task.async(fn -> Session.run(session, "go") end)
    assert_receive :running, 1000

    assert {:ok, %{cancelled: true}} = Commands.dispatch(session, "cancel", %{})
    assert {:error, :cancelled} = Task.await(task)
  end

  test "reset is refused during a run" do
    session = start(model_fun: blocking_model(self()))
    task = Task.async(fn -> Session.run(session, "go") end)
    assert_receive :running, 1000

    assert {:error, message} = Commands.dispatch(session, "reset", %{})
    assert message =~ "cannot reset"

    Session.cancel(session)
    Task.await(task)
  end
end
