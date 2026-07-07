defmodule Epix.GitTest do
  @moduledoc "Exercises the headless git plumbing layer against real bare repos."
  use ExUnit.Case, async: true

  alias Epix.Git

  @moduletag :tmp_dir

  setup context do
    git_dir = Path.join(context.tmp_dir, "repo.git")
    :ok = Git.init(git_dir)
    %{git_dir: git_dir}
  end

  describe "available?/0" do
    test "reports whether the git binary is on PATH" do
      assert Git.available?() == (System.find_executable("git") != nil)
    end
  end

  describe "init/2 and repo?/1" do
    test "creates a bare repo with HEAD on the default branch", %{git_dir: git_dir} do
      assert Git.repo?(git_dir)
      assert {:ok, "ref: refs/heads/main\n"} = File.read(Path.join(git_dir, "HEAD"))
    end

    test "honors a custom default branch", %{tmp_dir: tmp} do
      git_dir = Path.join(tmp, "trunk.git")
      :ok = Git.init(git_dir, default_branch: "trunk")
      assert {:ok, "ref: refs/heads/trunk\n"} = File.read(Path.join(git_dir, "HEAD"))
    end

    test "a non-repo directory is not a repo", %{tmp_dir: tmp} do
      refute Git.repo?(Path.join(tmp, "nope"))
    end
  end

  describe "commit/5 — first commit" do
    test "writes files and reads them back", %{git_dir: git_dir} do
      changes = [{:put, "README.md", "hello"}, {:put, "lib/a.ex", "defmodule A"}]
      assert {:ok, sha} = Git.commit(git_dir, "main", changes, "init")

      assert {:ok, ^sha} = Git.resolve(git_dir, "main")
      assert {:ok, "hello"} = Git.read(git_dir, "main", "README.md")
      assert {:ok, "defmodule A"} = Git.read(git_dir, "main", "lib/a.ex")
    end

    test "records author identity and message in the log", %{git_dir: git_dir} do
      author = %{name: "Ada", email: "ada@example.com", date: "2026-01-02T03:04:05+00:00"}
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "f", "x"}], "first", author: author)

      assert {:ok, [entry]} = Git.log(git_dir, "main")
      assert entry.author == "Ada"
      assert entry.email == "ada@example.com"
      assert entry.message == "first"
      # The instant is preserved; git may render the zero offset as `Z` or `+00:00`.
      assert entry.date =~ "2026-01-02T03:04:05"
    end

    test "a leading-slash path is normalized to repo-relative", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "/abs.txt", "v"}], "abs")
      assert {:ok, "v"} = Git.read(git_dir, "main", "abs.txt")
    end

    test "binary content with NUL bytes round-trips", %{git_dir: git_dir} do
      blob = <<0, 1, 2, 255, 0, 10>>
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "bin", blob}], "binary")
      assert {:ok, ^blob} = Git.read(git_dir, "main", "bin")
    end
  end

  describe "commit/5 — change-sets over a base" do
    setup %{git_dir: git_dir} do
      {:ok, base} =
        Git.commit(git_dir, "main", [{:put, "a.txt", "1"}, {:put, "dir/b.txt", "2"}], "base")

      %{base: base}
    end

    test "links to the parent and is reachable in the log", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "c.txt", "3"}], "second")
      assert {:ok, [second, first]} = Git.log(git_dir, "main")
      assert second.message == "second"
      assert first.message == "base"
    end

    test "delete removes a file", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:rm, "a.txt"}], "drop a")
      assert {:error, :not_found} = Git.read(git_dir, "main", "a.txt")
      assert {:ok, "2"} = Git.read(git_dir, "main", "dir/b.txt")
    end

    test "deleting a missing file is :not_found", %{git_dir: git_dir} do
      assert {:error, :not_found} = Git.commit(git_dir, "main", [{:rm, "ghost"}], "x")
    end

    test "move relocates content and removes the source", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:mv, "a.txt", "moved/a.txt"}], "mv")
      assert {:error, :not_found} = Git.read(git_dir, "main", "a.txt")
      assert {:ok, "1"} = Git.read(git_dir, "main", "moved/a.txt")
    end

    test "copy duplicates content and keeps the source", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:cp, "a.txt", "a-copy.txt"}], "cp")
      assert {:ok, "1"} = Git.read(git_dir, "main", "a.txt")
      assert {:ok, "1"} = Git.read(git_dir, "main", "a-copy.txt")
    end

    test "moving a missing source is :not_found", %{git_dir: git_dir} do
      assert {:error, :not_found} = Git.commit(git_dir, "main", [{:mv, "ghost", "x"}], "x")
    end

    test "later changes see earlier ones within the same commit", %{git_dir: git_dir} do
      changes = [{:put, "new.txt", "fresh"}, {:mv, "new.txt", "final.txt"}]
      {:ok, _} = Git.commit(git_dir, "main", changes, "write-then-move")
      assert {:error, :not_found} = Git.read(git_dir, "main", "new.txt")
      assert {:ok, "fresh"} = Git.read(git_dir, "main", "final.txt")
    end

    test "an effectively empty change-set is rejected", %{git_dir: git_dir} do
      assert {:error, :nothing_to_commit} =
               Git.commit(git_dir, "main", [{:put, "a.txt", "1"}], "noop")
    end

    test "allow_empty forces a commit with no tree change", %{git_dir: git_dir} do
      assert {:ok, _} =
               Git.commit(git_dir, "main", [{:put, "a.txt", "1"}], "noop", allow_empty: true)

      assert {:ok, log} = Git.log(git_dir, "main")
      assert length(log) == 2
    end
  end

  describe "commit/5 — compare-and-swap" do
    test "a stale base is rejected as :conflict and leaves the ref untouched", %{git_dir: git_dir} do
      {:ok, base} = Git.commit(git_dir, "main", [{:put, "a", "1"}], "base")
      {:ok, advanced} = Git.commit(git_dir, "main", [{:put, "b", "2"}], "advance")

      # A writer that based its work on the original tip must lose the race.
      assert {:error, :conflict} =
               Git.commit(git_dir, "main", [{:put, "c", "3"}], "stale", base: base)

      assert {:ok, ^advanced} = Git.resolve(git_dir, "main")
    end
  end

  describe "reads" do
    setup %{git_dir: git_dir} do
      changes = [
        {:put, "top.txt", "T"},
        {:put, "src/one.ex", "one"},
        {:put, "src/two.ex", "two"},
        {:put, "src/nested/deep.ex", "deep"}
      ]

      {:ok, _} = Git.commit(git_dir, "main", changes, "tree")
      :ok
    end

    test "list of the root is one level deep", %{git_dir: git_dir} do
      assert {:ok, entries} = Git.list(git_dir, "main")
      names = entries |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["src", "top.txt"]
      assert Enum.find(entries, &(&1.name == "src")).type == :dir
      top = Enum.find(entries, &(&1.name == "top.txt"))
      assert top.type == :file
      assert top.size == 1
    end

    test "list of a subdirectory returns repo-relative paths", %{git_dir: git_dir} do
      assert {:ok, entries} = Git.list(git_dir, "main", "src")
      by_name = Map.new(entries, &{&1.name, &1})
      assert by_name["one.ex"].path == "src/one.ex"
      assert by_name["nested"].type == :dir
    end

    test "recursive list flattens the whole tree", %{git_dir: git_dir} do
      assert {:ok, entries} = Git.list(git_dir, "main", "", recursive: true)
      paths = entries |> Enum.map(& &1.path) |> Enum.sort()
      assert "src/nested/deep.ex" in paths
      assert "top.txt" in paths
      assert Enum.all?(entries, &(&1.type == :file))
    end

    test "exists?/3 distinguishes present from absent", %{git_dir: git_dir} do
      assert Git.exists?(git_dir, "main", "src/one.ex")
      assert Git.exists?(git_dir, "main", "src")
      refute Git.exists?(git_dir, "main", "src/missing.ex")
    end

    test "stat/3 reports type and size", %{git_dir: git_dir} do
      assert {:ok, %{type: :file, size: 3}} = Git.stat(git_dir, "main", "src/one.ex")
      assert {:ok, %{type: :dir}} = Git.stat(git_dir, "main", "src")
      assert {:error, :not_found} = Git.stat(git_dir, "main", "nope")
    end

    test "reading a missing file or a directory is :not_found", %{git_dir: git_dir} do
      assert {:error, :not_found} = Git.read(git_dir, "main", "nope")
      assert {:error, :not_found} = Git.read(git_dir, "main", "src")
    end

    test "log honors :limit and :path", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "src/one.ex", "one!"}], "touch one")
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "top.txt", "T2"}], "touch top")

      assert {:ok, [only]} = Git.log(git_dir, "main", limit: 1)
      assert only.message == "touch top"

      assert {:ok, commits} = Git.log(git_dir, "main", path: "src/one.ex")
      messages = Enum.map(commits, & &1.message)
      assert "touch one" in messages
      refute "touch top" in messages
    end

    test "diff/4 shows changes between two revs", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "top.txt", "changed"}], "change top")
      assert {:ok, diff} = Git.diff(git_dir, "main~1", "main")
      assert diff =~ "top.txt"
      assert diff =~ "+changed"
    end
  end

  describe "branches" do
    test "lists branches and reads across them", %{git_dir: git_dir} do
      {:ok, base} = Git.commit(git_dir, "main", [{:put, "f", "main-v"}], "base")
      {:ok, ^base} = Git.create_branch(git_dir, "feature", "main")
      {:ok, _} = Git.commit(git_dir, "feature", [{:put, "f", "feature-v"}], "diverge")

      assert {:ok, branches} = Git.branches(git_dir)
      assert branches |> Enum.map(& &1.name) |> Enum.sort() == ["feature", "main"]

      # Reads span all branches even though only "feature" was written to last.
      assert {:ok, "main-v"} = Git.read(git_dir, "main", "f")
      assert {:ok, "feature-v"} = Git.read(git_dir, "feature", "f")
    end

    test "create_branch on an existing name is :exists", %{git_dir: git_dir} do
      {:ok, _} = Git.commit(git_dir, "main", [{:put, "f", "v"}], "base")
      assert {:error, :exists} = Git.create_branch(git_dir, "main", "main")
    end

    test "create_branch from an unknown rev is :not_found", %{git_dir: git_dir} do
      assert {:error, :not_found} = Git.create_branch(git_dir, "x", "nope")
    end
  end

  describe "empty repository" do
    test "resolving an unborn branch is :not_found", %{git_dir: git_dir} do
      assert {:error, :not_found} = Git.resolve(git_dir, "main")
    end

    test "branches/1 is empty before the first commit", %{git_dir: git_dir} do
      assert {:ok, []} = Git.branches(git_dir)
    end
  end
end
