defmodule EpixTest do
  use ExUnit.Case

  test "system prompt documents the host API surface" do
    prompt = Epix.SystemPrompt.build()
    assert prompt =~ "host.echo"
    assert prompt =~ "host.add(a, b)"
    assert prompt =~ "lua_define_tool"
  end

  test "tool specs expose the four meta-tools" do
    names = Epix.Tools.specs() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["lua_define_tool", "lua_eval", "lua_list_tools", "lua_run_tool"]
  end
end
