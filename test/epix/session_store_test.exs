defmodule Epix.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Epix.{SessionStore, Store}
  alias ReqLLM.Message

  @moduletag :tmp_dir

  setup context do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _sup} = Store.start_link(name: name, dir: context.tmp_dir)
    %{store: name}
  end

  defp msg(role, text), do: %Message{role: role, content: [%{type: :text, text: text}]}

  test "save/load round-trips a record", %{store: store} do
    assert SessionStore.load(store, "x") == nil

    messages = [msg(:system, "sys"), msg(:user, "hi")]
    :ok = SessionStore.save(store, "x", %{messages: messages, namespaces: ["agent:x"]})

    record = SessionStore.load(store, "x")
    assert record.id == "x"
    assert record.messages == messages
    assert record.namespaces == ["agent:x"]
    assert is_integer(record.updated_at)
  end

  test "list summarizes saved sessions", %{store: store} do
    SessionStore.save(store, "a", %{messages: [msg(:user, "1")], namespaces: []})

    SessionStore.save(store, "b", %{
      messages: [msg(:user, "1"), msg(:assistant, "2")],
      namespaces: []
    })

    list = SessionStore.list(store)
    assert Enum.map(list, & &1.id) |> Enum.sort() == ["a", "b"]
    assert Enum.find(list, &(&1.id == "b")).messages == 2
  end

  test "delete removes a record", %{store: store} do
    SessionStore.save(store, "x", %{messages: [], namespaces: []})
    assert :ok = SessionStore.delete(store, "x")
    assert SessionStore.load(store, "x") == nil
  end
end
