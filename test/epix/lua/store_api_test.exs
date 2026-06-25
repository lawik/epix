defmodule Epix.Lua.StoreApiTest do
  @moduledoc "Exercises the Lua-facing `store` API end to end through the Sandbox."
  use ExUnit.Case, async: true

  alias Epix.Lua.Sandbox
  alias Epix.Store

  @moduletag :tmp_dir

  setup context do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _sup} = Store.start_link(name: name, dir: context.tmp_dir)
    {:ok, sandbox} = Sandbox.start_link(store: name, namespaces: ["user:5", "proj"])
    %{sandbox: sandbox}
  end

  test "scalars round-trip through put/get", %{sandbox: s} do
    assert {:ok, "true"} = Sandbox.eval(s, ~s|return store.put("user:5", "name", "Ada")|)
    assert {:ok, ~s("Ada")} = Sandbox.eval(s, ~s|return store.get("user:5", "name")|)

    assert {:ok, "42"} =
             Sandbox.eval(s, ~s|store.put("user:5", "n", 42); return store.get("user:5", "n")|)
  end

  test "a missing key reads back as nil", %{sandbox: s} do
    assert {:ok, result} = Sandbox.eval(s, ~s|return store.get("user:5", "missing")|)
    assert result in ["nil", "null"]
  end

  test "tables round-trip as nested data", %{sandbox: s} do
    Sandbox.eval(s, ~s|store.put("user:5", "prefs", {theme = "dark", n = 3})|)
    assert {:ok, ~s("dark")} = Sandbox.eval(s, ~s|return store.get("user:5", "prefs").theme|)
    assert {:ok, "3"} = Sandbox.eval(s, ~s|return store.get("user:5", "prefs").n|)
  end

  test "arrays round-trip", %{sandbox: s} do
    Sandbox.eval(s, ~s|store.put("user:5", "xs", {10, 20, 30})|)
    assert {:ok, "20"} = Sandbox.eval(s, ~s|return store.get("user:5", "xs")[2]|)
  end

  test "delete removes a key", %{sandbox: s} do
    Sandbox.eval(s, ~s|store.put("user:5", "k", 1)|)
    assert {:ok, "true"} = Sandbox.eval(s, ~s|return store.delete("user:5", "k")|)
    assert {:ok, result} = Sandbox.eval(s, ~s|return store.get("user:5", "k")|)
    assert result in ["nil", "null"]
  end

  test "keys() and namespaces() reflect contents and grants", %{sandbox: s} do
    Sandbox.eval(s, ~s|store.put("proj", "a", 1); store.put("proj", "b", 2)|)

    assert {:ok, ~s("a,b")} =
             Sandbox.eval(s, ~s|local k = store.keys("proj"); return k[1] .. "," .. k[2]|)

    assert {:ok, "2"} = Sandbox.eval(s, ~s|return #store.namespaces()|)
  end

  test "an ungranted namespace is refused", %{sandbox: s} do
    assert {:error, message} = Sandbox.eval(s, ~s|return store.put("secret", "k", 1)|)
    assert message =~ "not accessible"
  end

  test "set_namespaces changes access at runtime", %{sandbox: s} do
    assert {:error, _} = Sandbox.eval(s, ~s|return store.put("fresh", "k", 1)|)

    :ok = Sandbox.set_namespaces(s, ["fresh"])
    assert {:ok, "true"} = Sandbox.eval(s, ~s|return store.put("fresh", "k", 1)|)
    # The previously-granted namespace is no longer accessible.
    assert {:error, _} = Sandbox.eval(s, ~s|return store.put("user:5", "k", 1)|)
  end

  test "without a configured store, the store table is absent" do
    {:ok, plain} = Sandbox.start_link(namespaces: ["user:5"])
    assert {:error, _} = Sandbox.eval(plain, ~s|return store.get("user:5", "k")|)
  end
end
