defmodule Epix.StoreTest do
  use ExUnit.Case, async: true

  alias Epix.Store

  @moduletag :tmp_dir

  setup context do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, sup} = Store.start_link(name: name, dir: context.tmp_dir)
    %{store: name, sup: sup}
  end

  test "put/get/delete within a namespace", %{store: store} do
    assert Store.get(store, "user:5", "name") == nil
    assert Store.put(store, "user:5", "name", "Ada") == :ok
    assert Store.get(store, "user:5", "name") == "Ada"
    assert Store.delete(store, "user:5", "name") == :ok
    assert Store.get(store, "user:5", "name") == nil
  end

  test "namespaces are isolated from each other", %{store: store} do
    Store.put(store, "a", "k", 1)
    Store.put(store, "b", "k", 2)
    assert Store.get(store, "a", "k") == 1
    assert Store.get(store, "b", "k") == 2
  end

  test "keys lists a namespace's keys in order", %{store: store} do
    Store.put(store, "ns", "b", 2)
    Store.put(store, "ns", "a", 1)
    assert Store.keys(store, "ns") == ["a", "b"]
    assert Store.keys(store, "empty") == []
  end

  test "stores arbitrary terms, including nested maps and lists", %{store: store} do
    value = %{"theme" => "dark", "tags" => ["x", "y"]}
    Store.put(store, "ns", "prefs", value)
    assert Store.get(store, "ns", "prefs") == value
  end

  test "data persists across a store restart", %{store: store, sup: sup, tmp_dir: dir} do
    Store.put(store, "ns", "k", "v")
    Supervisor.stop(sup)

    {:ok, _sup} = Store.start_link(name: store, dir: dir)
    assert Store.get(store, "ns", "k") == "v"
  end
end
