defmodule Epix.SystemPromptTest do
  @moduledoc "The capability sections are gated independently by their flags."
  use ExUnit.Case, async: true

  alias Epix.SystemPrompt

  test "always-on utilities (time, bytes) are documented with no capabilities" do
    prompt = SystemPrompt.build()
    assert prompt =~ "time.now()"
    assert prompt =~ "bytes.hexdump"
    refute prompt =~ "kv.get"
    refute prompt =~ "web.search"
    refute prompt =~ "git.commit"
    refute prompt =~ "fs.write"
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

  test "fs flag gates the fs section" do
    prompt = SystemPrompt.build(fs: true)
    assert prompt =~ "fs.write"
    assert prompt =~ "fs.namespaces()"
    refute SystemPrompt.build(fs: false) =~ "fs.write"
  end
end
