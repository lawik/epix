defmodule Epix.Lua.GitApiTest do
  @moduledoc "Exercises the Lua-facing `git` API end to end through the Sandbox."
  use ExUnit.Case, async: true

  alias Epix.Git
  alias Epix.Lua.Sandbox

  @moduletag :tmp_dir

  # Two bare repos: "docs" is read-only, "work" is writable on "main". A third repo
  # exists on disk but is never granted, so the agent must not be able to touch it.
  setup context do
    docs = Path.join(context.tmp_dir, "docs.git")
    work = Path.join(context.tmp_dir, "work.git")
    :ok = Git.init(docs)
    :ok = Git.init(work)

    {:ok, _} =
      Git.commit(docs, "main", [{:put, "README.md", "hello"}, {:put, "src/a.ex", "A"}], "seed")

    {:ok, _} = Git.commit(work, "main", [{:put, "start.txt", "x"}], "seed")

    {:ok, s} =
      Sandbox.start_link(
        git: [
          %{name: "docs", dir: docs},
          %{name: "work", dir: work, writable: ["main"]}
        ]
      )

    %{sandbox: s, docs: docs, work: work}
  end

  describe "grants" do
    test "repos() reports names and writability", %{sandbox: s} do
      assert {:ok, "2"} = Sandbox.eval(s, "return #git.repos()")

      assert {:ok, "false"} =
               eval_find(s, "docs", "return r.writable")

      assert {:ok, ~s("main")} =
               eval_find(s, "work", "return r.writable[1]")
    end

    test "touching an ungranted repo raises", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~s|return git.read("secret", "main", "x")|)
      assert msg =~ "not accessible"
    end
  end

  describe "reads" do
    test "read returns bytes, or nil when absent", %{sandbox: s} do
      assert {:ok, ~s("hello")} =
               Sandbox.eval(s, ~s|return git.read("docs", "main", "README.md")|)

      assert {:ok, missing} = Sandbox.eval(s, ~s|return git.read("docs", "main", "nope")|)
      assert missing in ["nil", "null"]
    end

    test "exists distinguishes present from absent", %{sandbox: s} do
      assert {:ok, "true"} = Sandbox.eval(s, ~s|return git.exists("docs", "main", "src/a.ex")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~s|return git.exists("docs", "main", "src")|)
      assert {:ok, "false"} = Sandbox.eval(s, ~s|return git.exists("docs", "main", "gone")|)
    end

    test "stat reports type and size", %{sandbox: s} do
      assert {:ok, "5"} = Sandbox.eval(s, ~s|return git.stat("docs", "main", "README.md").size|)

      assert {:ok, ~s("file")} =
               Sandbox.eval(s, ~s|return git.stat("docs", "main", "README.md").type|)

      assert {:ok, ~s("dir")} = Sandbox.eval(s, ~s|return git.stat("docs", "main", "src").type|)
    end

    test "list returns entries with repo-relative paths", %{sandbox: s} do
      assert {:ok, "2"} = Sandbox.eval(s, ~s|return #git.list("docs", "main")|)

      assert {:ok, ~s("src/a.ex")} =
               Sandbox.eval(s, ~s|return git.list("docs", "main", "src")[1].path|)
    end

    test "recursive list flattens the tree", %{sandbox: s} do
      code = ~s|
        local n = 0
        for _, e in ipairs(git.list("docs", "main", "", true)) do
          if e.path == "src/a.ex" then n = n + 1 end
        end
        return n|

      assert {:ok, "1"} = Sandbox.eval(s, code)
    end

    test "log returns commits newest-first", %{sandbox: s} do
      assert {:ok, ~s("seed")} = Sandbox.eval(s, ~s|return git.log("docs", "main")[1].message|)
    end

    test "resolve returns a full sha, or nil", %{sandbox: s} do
      assert {:ok, "40"} = Sandbox.eval(s, ~s|return #git.resolve("docs", "main")|)

      assert {:ok, missing} = Sandbox.eval(s, ~s|return git.resolve("docs", "nope")|)
      assert missing in ["nil", "null"]
    end

    test "branches lists local branches", %{sandbox: s} do
      assert {:ok, ~s("main")} = Sandbox.eval(s, ~s|return git.branches("docs")[1].name|)
    end
  end

  describe "writes" do
    test "commit applies a change-set to a writable branch", %{sandbox: s} do
      code = ~s|
        git.commit("work", "main", {
          {op = "put", path = "new.txt", content = "fresh"},
          {op = "mv", from = "start.txt", to = "moved.txt"},
        }, "add and move")
        return git.read("work", "main", "new.txt") .. ";" ..
          tostring(git.exists("work", "main", "start.txt")) .. ";" ..
          git.read("work", "main", "moved.txt")|

      assert {:ok, ~s("fresh;false;x")} = Sandbox.eval(s, code)
    end

    test "commit returns the new sha", %{sandbox: s} do
      assert {:ok, "40"} =
               Sandbox.eval(
                 s,
                 ~s|return #git.commit("work", "main", {{op = "put", path = "f", content = "v"}}, "c")|
               )
    end

    test "commit to a read-only repo is refused", %{sandbox: s} do
      assert {:error, msg} =
               Sandbox.eval(
                 s,
                 ~s|return git.commit("docs", "main", {{op = "put", path = "x", content = "y"}}, "no")|
               )

      assert msg =~ "not writable"
    end

    test "commit to an ungranted branch is refused", %{sandbox: s} do
      assert {:error, msg} =
               Sandbox.eval(
                 s,
                 ~s|return git.commit("work", "other", {{op = "put", path = "x", content = "y"}}, "no")|
               )

      assert msg =~ "not writable"
    end

    test "a malformed change reports which fields are needed", %{sandbox: s} do
      assert {:error, msg} =
               Sandbox.eval(
                 s,
                 ~s|return git.commit("work", "main", {{op = "put", path = "x"}}, "c")|
               )

      assert msg =~ "put"
    end

    test "create_branch on a non-writable name is refused", %{sandbox: s} do
      # "work" grants writes only to "main", so creating "main-wip" is refused.
      assert {:error, msg} =
               Sandbox.eval(s, ~s|return git.create_branch("work", "main-wip", "main")|)

      assert msg =~ "not writable"
    end
  end

  describe "writable :all" do
    setup context do
      repo = Path.join(context.tmp_dir, "all.git")
      :ok = Git.init(repo)
      {:ok, _} = Git.commit(repo, "main", [{:put, "f", "v"}], "seed")
      {:ok, s} = Sandbox.start_link(git: [%{name: "all", dir: repo, writable: :all}])
      %{all_sandbox: s}
    end

    test "any branch is writable, including newly created ones", %{all_sandbox: s} do
      code = ~s|
        git.create_branch("all", "feature", "main")
        git.commit("all", "feature", {{op = "put", path = "g", content = "w"}}, "add")
        return git.read("all", "feature", "g")|

      assert {:ok, ~s("w")} = Sandbox.eval(s, code)
    end
  end

  # Runs `code` with `r` bound to the repo table named `name` from git.repos().
  defp eval_find(sandbox, name, code) do
    Sandbox.eval(sandbox, ~s|
      for _, r in ipairs(git.repos()) do
        if r.name == "#{name}" then #{code} end
      end|)
  end
end
