defmodule EpixTest do
  use ExUnit.Case

  test "system prompt documents the Lua API surface" do
    prompt = Epix.SystemPrompt.build()
    assert prompt =~ "time.now()"
    assert prompt =~ "lua_define_tool"
  end

  test "the system prompt documents the kv API only when storage is enabled" do
    refute Epix.SystemPrompt.build(storage: false) =~ "kv.put"
    assert Epix.SystemPrompt.build(storage: true) =~ "kv.put"
  end

  test "the system prompt documents the web API only when search is enabled" do
    refute Epix.SystemPrompt.build(web: false) =~ "web.search"
    assert Epix.SystemPrompt.build(web: true) =~ "web.search"
  end

  test "tool specs expose the meta-tools, including list_namespaces" do
    names = Epix.Tools.specs() |> Enum.map(& &1.name) |> Enum.sort()

    assert names == [
             "list_namespaces",
             "lua_define_tool",
             "lua_eval",
             "lua_list_tools",
             "lua_run_tool"
           ]
  end
end
