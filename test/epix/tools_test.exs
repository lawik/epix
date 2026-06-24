defmodule Epix.ToolsTest do
  use ExUnit.Case, async: true

  alias Epix.Lua.Sandbox
  alias Epix.Tools

  setup do
    {:ok, sandbox} = Sandbox.start_link()
    %{sandbox: sandbox}
  end

  test "lua_eval routes code to the sandbox", %{sandbox: s} do
    assert {:ok, "4"} = Tools.dispatch("lua_eval", %{"code" => "return 2 + 2"}, s)
  end

  test "lua_define_tool then lua_run_tool round-trips", %{sandbox: s} do
    assert {:ok, msg} =
             Tools.dispatch(
               "lua_define_tool",
               %{
                 "name" => "dbl",
                 "description" => "d",
                 "params" => ["x"],
                 "code" => "return host.add(x, x)"
               },
               s
             )

    assert msg =~ "Defined tool"

    assert {:ok, "42"} =
             Tools.dispatch("lua_run_tool", %{"name" => "dbl", "arguments" => %{"x" => 21}}, s)
  end

  test "lua_define_tool defaults missing description/params, lua_run_tool defaults missing arguments",
       %{sandbox: s} do
    assert {:ok, _} =
             Tools.dispatch("lua_define_tool", %{"name" => "one", "code" => "return 1"}, s)

    assert {:ok, "1"} = Tools.dispatch("lua_run_tool", %{"name" => "one"}, s)
  end

  test "lua_list_tools: empty then populated", %{sandbox: s} do
    assert {:ok, "No tools defined yet."} = Tools.dispatch("lua_list_tools", %{}, s)

    Tools.dispatch(
      "lua_define_tool",
      %{"name" => "t", "description" => "does a thing", "code" => "return 1"},
      s
    )

    assert {:ok, listing} = Tools.dispatch("lua_list_tools", %{}, s)
    assert listing =~ "t"
    assert listing =~ "does a thing"
  end

  test "an unknown tool name is reported, not crashed", %{sandbox: s} do
    assert {:error, message} = Tools.dispatch("nope", %{}, s)
    assert message =~ "unknown tool"
  end

  test "a sandbox error is surfaced as an error tuple", %{sandbox: s} do
    assert {:error, _message} = Tools.dispatch("lua_eval", %{"code" => "return ("}, s)
  end
end
