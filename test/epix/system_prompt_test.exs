defmodule Epix.SystemPromptTest do
  @moduledoc "The capability sections are gated independently by their flags."
  use ExUnit.Case, async: true

  alias Epix.SystemPrompt

  test "no capabilities: only time is documented" do
    prompt = SystemPrompt.build()
    assert prompt =~ "time.now()"
    refute prompt =~ "kv.get"
    refute prompt =~ "web.search"
    refute prompt =~ "git.commit"
  end

  test "storage flag gates the kv section" do
    assert SystemPrompt.build(storage: true) =~ "kv.get"
    refute SystemPrompt.build(storage: false) =~ "kv.get"
  end

  test "web flag gates the web section" do
    assert SystemPrompt.build(web: true) =~ "web.search"
    refute SystemPrompt.build(web: false) =~ "web.search"
  end

  test "git flag gates the git section" do
    prompt = SystemPrompt.build(git: true)
    assert prompt =~ "git.repos()"
    assert prompt =~ "git.commit"
    refute SystemPrompt.build(git: false) =~ "git.commit"
  end
end
