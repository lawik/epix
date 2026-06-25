defmodule Epix.SessionPersistenceTest do
  use ExUnit.Case, async: true

  alias Epix.{Session, SessionStore, Store}
  alias Epix.Loop.Turn
  alias ReqLLM.Message

  @moduletag :tmp_dir

  defp done_turn,
    do: %Turn{message: %Message{role: :assistant, content: []}, text: "ok", finish_reason: :stop}

  defp instant_model, do: fn _ctx, _cfg, _rctx -> {:ok, done_turn()} end

  setup context do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _sup} = Store.start_link(name: name, dir: context.tmp_dir)
    %{store: name}
  end

  test "id/1 returns the configured id; the default is a UUID", %{store: store} do
    {:ok, fixed} =
      Session.start_link(model_fun: instant_model(), id: "abc", persist: store, store: store)

    assert Session.id(fixed) == "abc"

    {:ok, fresh} = Session.start_link(model_fun: instant_model())
    assert Session.id(fresh) =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  end

  test "a session persists after a run and resumes by id", %{store: store} do
    base = [model_fun: instant_model(), persist: store, store: store]

    {:ok, first} = Session.start_link([id: "sess-1", namespaces: ["agent:sess-1"]] ++ base)
    assert {:ok, _} = Session.run(first, "remember: the sky is blue")
    GenServer.stop(first)

    {:ok, resumed} = Session.start_link([id: "sess-1"] ++ base)
    roles = Enum.map(Session.context(resumed).messages, & &1.role)
    assert roles == [:system, :user, :assistant]
    # The granted namespace is restored too (its kv data persists on its own).
    assert Session.namespaces(resumed) == ["agent:sess-1"]
  end

  test "an unknown id starts a fresh conversation", %{store: store} do
    {:ok, session} =
      Session.start_link(model_fun: instant_model(), id: "nope", persist: store, store: store)

    assert Enum.map(Session.context(session).messages, & &1.role) == [:system]
  end

  test "without :persist nothing is saved", %{store: store} do
    {:ok, session} = Session.start_link(model_fun: instant_model(), id: "ghost", store: store)
    assert {:ok, _} = Session.run(session, "hi")
    assert SessionStore.load(store, "ghost") == nil
  end
end
