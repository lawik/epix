defmodule EpixTest do
  use ExUnit.Case

  test "system prompt documents the host API surface" do
    prompt = Epix.SystemPrompt.build()
    assert prompt =~ "host.echo"
    assert prompt =~ "host.add(a, b)"
    assert prompt =~ "lua_define_tool"
  end

  test "the system prompt documents the store API only when storage is enabled" do
    refute Epix.SystemPrompt.build(storage: false) =~ "store.put"
    assert Epix.SystemPrompt.build(storage: true) =~ "store.put"
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
