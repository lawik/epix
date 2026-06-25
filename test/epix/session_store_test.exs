defmodule Epix.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Epix.SessionStore
  alias ReqLLM.Message

  @moduletag :tmp_dir

  defp msg(role, text), do: %Message{role: role, content: [%{type: :text, text: text}]}

  defp record(messages, namespaces \\ []),
    do: %{messages: messages, namespaces: namespaces, updated_at: 1}

  test "each session is its own db under an id-named directory", %{tmp_dir: dir} do
    {:ok, db} = SessionStore.open(dir, "sess-1")
    assert SessionStore.load(db) == nil

    rec = record([msg(:user, "hi")], ["agent:sess-1"])
    :ok = SessionStore.save(db, rec)
    assert SessionStore.load(db) == rec
    assert File.dir?(Path.join(dir, "sess-1"))
    CubDB.stop(db)
  end

  test "data survives reopening the same session db", %{tmp_dir: dir} do
    {:ok, db} = SessionStore.open(dir, "x")
    SessionStore.save(db, record([msg(:user, "remember")]))
    CubDB.stop(db)

    {:ok, reopened} = SessionStore.open(dir, "x")
    assert SessionStore.load(reopened).messages == [msg(:user, "remember")]
    CubDB.stop(reopened)
  end

  test "list returns the id-named directories (the session index)", %{tmp_dir: dir} do
    for id <- ["a", "b"] do
      {:ok, db} = SessionStore.open(dir, id)
      SessionStore.save(db, record([]))
      CubDB.stop(db)
    end

    assert Enum.sort(SessionStore.list(dir)) == ["a", "b"]
    assert SessionStore.list(Path.join(dir, "nope")) == []
  end

  test "delete removes a session's directory", %{tmp_dir: dir} do
    {:ok, db} = SessionStore.open(dir, "x")
    SessionStore.save(db, record([]))
    CubDB.stop(db)

    assert :ok = SessionStore.delete(dir, "x")
    refute File.dir?(Path.join(dir, "x"))
    assert SessionStore.list(dir) == []
  end
end
