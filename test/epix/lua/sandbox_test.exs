defmodule Epix.Lua.SandboxTest do
  use ExUnit.Case, async: true

  alias Epix.Lua.Sandbox

  setup do
    {:ok, pid} = Sandbox.start_link()
    %{sandbox: pid}
  end

  describe "eval/2" do
    test "evaluates arithmetic", %{sandbox: s} do
      assert {:ok, "4"} = Sandbox.eval(s, "return 2 + 2")
    end

    test "exposes the host API", %{sandbox: s} do
      assert {:ok, ~s("HI")} = Sandbox.eval(s, "return host.upper('hi')")
      assert {:ok, "42"} = Sandbox.eval(s, "return host.add(40, 2)")
    end

    test "keeps standard string/table/math libs", %{sandbox: s} do
      assert {:ok, "3"} = Sandbox.eval(s, "return #'abc'")
      assert {:ok, "4"} = Sandbox.eval(s, "return math.floor(4.7)")
    end

    test "formats no/single/multiple return values", %{sandbox: s} do
      assert {:ok, "nil"} = Sandbox.eval(s, "return")
      assert {:ok, ~s("hi")} = Sandbox.eval(s, "return 'hi'")
      assert {:ok, "[1, 2, 3]"} = Sandbox.eval(s, "return 1, 2, 3")
    end

    test "blocks dangerous libraries", %{sandbox: s} do
      assert {:error, _} = Sandbox.eval(s, "return os.getenv('HOME')")
    end

    test "returns compile errors mentioning the failure", %{sandbox: s} do
      assert {:error, message} = Sandbox.eval(s, "return (")
      assert message =~ ~r/compile/i
    end

    test "returns runtime errors", %{sandbox: s} do
      assert {:error, message} = Sandbox.eval(s, "return host.nope()")
      assert is_binary(message) and message != ""
    end

    test "host functions raise a clean error on bad arguments (no module leak)", %{sandbox: s} do
      assert {:error, message} = Sandbox.eval(s, "return host.add(1)")
      assert message =~ "host.add expects"
      refute message =~ "Epix.Lua.HostApi"

      assert {:error, message} = Sandbox.eval(s, "return host.upper(123)")
      assert message =~ "host.upper expects"
    end

    test "unencodable values are not leaked via inspect", %{sandbox: s} do
      # echo of a function ref cannot be JSON-encoded; must not leak Erlang internals.
      assert {:ok, "<unencodable lua value>"} = Sandbox.eval(s, "return host.echo(print)")
    end
  end

  describe "define_tool/5 and run_tool/3" do
    test "defines, lists, and runs a tool", %{sandbox: s} do
      assert :ok =
               Sandbox.define_tool(s, "double", "doubles x", ["x"], "return host.add(x, x)")

      assert [%{name: "double", params: ["x"]}] = Sandbox.list_tools(s)
      assert {:ok, "42"} = Sandbox.run_tool(s, "double", %{"x" => 21})
    end

    test "rejects a tool that does not compile", %{sandbox: s} do
      assert {:error, _} = Sandbox.define_tool(s, "bad", "broken", [], "return (")
      assert [] = Sandbox.list_tools(s)
    end

    test "errors when running an unknown tool", %{sandbox: s} do
      assert {:error, message} = Sandbox.run_tool(s, "ghost", %{})
      assert message =~ "no tool named"
    end

    test "surfaces runtime errors from a tool body", %{sandbox: s} do
      assert :ok = Sandbox.define_tool(s, "boom", "fails", [], "return nothing.here")
      assert {:error, _} = Sandbox.run_tool(s, "boom", %{})
    end

    test "rejects a non-identifier parameter name", %{sandbox: s} do
      assert {:error, message} = Sandbox.define_tool(s, "t", "d", ["bad-name"], "return 1")
      assert message =~ "invalid parameter name"
      assert [] = Sandbox.list_tools(s)
    end
  end
end
