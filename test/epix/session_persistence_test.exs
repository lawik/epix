defmodule Epix.SessionPersistenceTest do
  use ExUnit.Case, async: true

  alias Epix.{Session, Store}
  alias Epix.Loop.Turn
  alias ReqLLM.Message

  @moduletag :tmp_dir

  defp done_turn,
    do: %Turn{message: %Message{role: :assistant, content: []}, text: "ok", finish_reason: :stop}

  defp instant_model, do: fn _ctx, _cfg, _rctx -> {:ok, done_turn()} end

  # A kv store (Epix.Store) and a *separate* directory for session storage.
  setup context do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _sup} = Store.start_link(name: name, dir: Path.join(context.tmp_dir, "kv"))
    %{store: name, sessions: Path.join(context.tmp_dir, "sessions")}
  end

  test "id/1 returns the configured id; the default is a UUID" do
    {:ok, fixed} = Session.start_link(model_fun: instant_model(), id: "abc")
    assert Session.id(fixed) == "abc"

    {:ok, fresh} = Session.start_link(model_fun: instant_model())
    assert Session.id(fresh) =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  end

  test "a session persists to its own backend and resumes by id", %{
    store: store,
    sessions: sessions
  } do
    base = [model_fun: instant_model(), persist: sessions, store: store]

    {:ok, first} = Session.start_link([id: "sess-1", namespaces: ["agent:sess-1"]] ++ base)
    assert {:ok, _} = Session.run(first, "remember: the sky is blue")
    GenServer.stop(first)

    {:ok, resumed} = Session.start_link([id: "sess-1"] ++ base)
    roles = Enum.map(Session.context(resumed).messages, & &1.role)
    assert roles == [:system, :user, :assistant]
    assert Session.namespaces(resumed) == ["agent:sess-1"]
  end

  test "a capability change (set_namespaces) is part of the persisted history", %{
    store: store,
    sessions: sessions
  } do
    base = [model_fun: instant_model(), persist: sessions, store: store]

    {:ok, session} = Session.start_link([id: "cap", namespaces: ["a"]] ++ base)
    :ok = Session.set_namespaces(session, ["a", "b"])
    GenServer.stop(session)

    {:ok, resumed} = Session.start_link([id: "cap"] ++ base)
    assert Session.namespaces(resumed) == ["a", "b"]
  end

  test "an unknown id starts a fresh conversation", %{sessions: sessions} do
    {:ok, session} = Session.start_link(model_fun: instant_model(), id: "nope", persist: sessions)
    assert Enum.map(Session.context(session).messages, & &1.role) == [:system]
  end

  test "without :persist nothing is written to the sessions directory", %{sessions: sessions} do
    {:ok, session} = Session.start_link(model_fun: instant_model(), id: "ghost")
    assert {:ok, _} = Session.run(session, "hi")
    refute File.dir?(Path.join(sessions, "ghost"))
  end
end
