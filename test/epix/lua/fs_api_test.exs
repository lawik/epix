defmodule Epix.Lua.FsApiTest do
  @moduledoc "Exercises the Lua-facing `fs` virtual filesystem end to end through the Sandbox."
  use ExUnit.Case, async: true

  alias Epix.Git
  alias Epix.Lua.Sandbox

  @moduletag :tmp_dir

  setup context do
    root = Path.join(context.tmp_dir, "fs")
    File.mkdir_p!(root)
    {:ok, s} = Sandbox.start_link(fs: root, namespaces: ["proj", "notes"])
    %{sandbox: s, root: root}
  end

  defp repo(root, ns), do: Path.join(root, ns <> ".git")

  # A run's writes are only visible to later runs once committed, so most tests
  # write in one eval and observe in the next.
  defp missing?(v), do: v in ["nil", "null"]

  describe "read-your-writes within a single run" do
    test "a read sees a write made earlier in the same run", %{sandbox: s} do
      code = ~S"""
      fs.write("proj", "a.txt", "hello")
      return fs.read("proj", "a.txt")
      """

      assert {:ok, ~s("hello")} = Sandbox.eval(s, code)
    end

    test "list reflects writes made in the same run", %{sandbox: s} do
      assert {:ok, "1"} =
               Sandbox.eval(s, ~S|fs.write("proj", "p.txt", "1"); return #fs.list("proj")|)
    end

    test "move sees a write made in the same run", %{sandbox: s} do
      code = ~S"""
      fs.write("proj", "tmp.txt", "data")
      fs.move("proj", "tmp.txt", "final.txt")
      return fs.read("proj", "final.txt")
      """

      assert {:ok, ~s("data")} = Sandbox.eval(s, code)
    end
  end

  describe "one run is one commit" do
    test "writes persist to the bare repo and to later runs", %{sandbox: s, root: root} do
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.write("proj", "dir/a.txt", "v1")|)

      # A human can read the namespace as an ordinary bare repo.
      assert {:ok, "v1"} = Git.read(repo(root, "proj"), "main", "dir/a.txt")
      # And a later run sees the committed file.
      assert {:ok, ~s("v1")} = Sandbox.eval(s, ~S|return fs.read("proj", "dir/a.txt")|)
    end

    test "all writes in a run collapse into a single commit", %{sandbox: s, root: root} do
      code = ~S"""
      fs.write("proj", "a.txt", "A")
      fs.write("proj", "b.txt", "B")
      fs.write("proj", "sub/c.txt", "C")
      """

      assert {:ok, _} = Sandbox.eval(s, code)
      assert {:ok, [commit]} = Git.log(repo(root, "proj"), "main")
      assert commit.message =~ "fs:"
      assert {:ok, "A"} = Git.read(repo(root, "proj"), "main", "a.txt")
      assert {:ok, "C"} = Git.read(repo(root, "proj"), "main", "sub/c.txt")
    end

    test "a run that raises commits nothing", %{sandbox: s, root: root} do
      # The bad arity raises after the write; the run's changes die with the VM.
      code = ~S"""
      fs.write("proj", "ghost.txt", "nope")
      return fs.read("proj")
      """

      assert {:error, _} = Sandbox.eval(s, code)
      refute Git.repo?(repo(root, "proj"))
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.read("proj", "ghost.txt")|)
      assert missing?(gone)
    end

    test "namespaces are isolated repos", %{sandbox: s, root: root} do
      Sandbox.eval(s, ~S|fs.write("proj", "a.txt", "P")|)
      Sandbox.eval(s, ~S|fs.write("notes", "a.txt", "N")|)
      assert {:ok, "P"} = Git.read(repo(root, "proj"), "main", "a.txt")
      assert {:ok, "N"} = Git.read(repo(root, "notes"), "main", "a.txt")
    end
  end

  describe "read / write" do
    test "read of a missing file is nil", %{sandbox: s} do
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.read("proj", "nope")|)
      assert missing?(gone)
    end

    test "write overwrites an existing file", %{sandbox: s} do
      Sandbox.eval(s, ~S|fs.write("proj", "f.txt", "v1")|)
      Sandbox.eval(s, ~S|fs.write("proj", "f.txt", "v2")|)
      assert {:ok, ~s("v2")} = Sandbox.eval(s, ~S|return fs.read("proj", "f.txt")|)
    end

    test "write rejects a non-string content", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~S|return fs.write("proj", "f.txt", 42)|)
      assert msg =~ "must be a string"
    end

    test "binary content round-trips via the bytes helpers", %{sandbox: s, root: root} do
      # The PNG signature, delivered as base64 and written as a binary file.
      Sandbox.eval(s, ~S|fs.write("proj", "sig.bin", bytes.from_base64("iVBORw0KGgo="))|)

      assert {:ok, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>} =
               Git.read(repo(root, "proj"), "main", "sig.bin")

      # And the model can read the raw bytes back as legible text.
      assert {:ok, ~s("89504e470d0a1a0a")} =
               Sandbox.eval(s, ~S|return bytes.hex(fs.read("proj", "sig.bin"))|)
    end
  end

  describe "remove" do
    test "removes a file", %{sandbox: s} do
      Sandbox.eval(s, ~S|fs.write("proj", "x.txt", "1")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.remove("proj", "x.txt")|)
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.read("proj", "x.txt")|)
      assert missing?(gone)
    end

    test "removes a directory and everything under it", %{sandbox: s} do
      Sandbox.eval(s, ~S"""
      fs.write("proj", "d/a.txt", "1")
      fs.write("proj", "d/e/b.txt", "2")
      fs.write("proj", "keep.txt", "k")
      """)

      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.remove("proj", "d")|)
      assert {:ok, a} = Sandbox.eval(s, ~S|return fs.read("proj", "d/a.txt")|)
      assert {:ok, b} = Sandbox.eval(s, ~S|return fs.read("proj", "d/e/b.txt")|)
      assert missing?(a) and missing?(b)
      assert {:ok, ~s("k")} = Sandbox.eval(s, ~S|return fs.read("proj", "keep.txt")|)
    end

    test "removing a missing path errors", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~S|return fs.remove("proj", "nope")|)
      assert msg =~ "does not exist"
    end
  end

  describe "move" do
    test "renames a file across runs", %{sandbox: s} do
      Sandbox.eval(s, ~S|fs.write("proj", "from.txt", "payload")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.move("proj", "from.txt", "to.txt")|)
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.read("proj", "from.txt")|)
      assert missing?(gone)
      assert {:ok, ~s("payload")} = Sandbox.eval(s, ~S|return fs.read("proj", "to.txt")|)
    end

    test "relocates a whole directory", %{sandbox: s} do
      Sandbox.eval(s, ~S|fs.write("proj", "old/a.txt", "1"); fs.write("proj", "old/b.txt", "2")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.move("proj", "old", "new")|)
      assert {:ok, ~s("1")} = Sandbox.eval(s, ~S|return fs.read("proj", "new/a.txt")|)
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.read("proj", "old/a.txt")|)
      assert missing?(gone)
    end
  end

  describe "list / exists / stat" do
    setup %{sandbox: s} do
      Sandbox.eval(s, ~S"""
      fs.write("proj", "top.txt", "T")
      fs.write("proj", "src/a.txt", "A")
      fs.write("proj", "src/deep/b.txt", "B")
      """)

      :ok
    end

    test "list of the root shows files and directories", %{sandbox: s} do
      assert {:ok, "2"} = Sandbox.eval(s, ~S|return #fs.list("proj")|)

      find_src = ~S"""
      for _, e in ipairs(fs.list("proj")) do
        if e.name == "src" then return e.type end
      end
      """

      assert {:ok, ~s("dir")} = Sandbox.eval(s, find_src)
    end

    test "recursive list flattens to files", %{sandbox: s} do
      assert {:ok, "3"} = Sandbox.eval(s, ~S|return #fs.list("proj", "", true)|)
    end

    test "a nil path means the root (as the model tends to pass it)", %{sandbox: s} do
      assert {:ok, "3"} = Sandbox.eval(s, ~S|return #fs.list("proj", nil, true)|)
      assert {:ok, "2"} = Sandbox.eval(s, ~S|return #fs.list("proj", nil)|)
    end

    test "a listing can be returned directly as a table", %{sandbox: s} do
      assert {:ok, json} = Sandbox.eval(s, ~S|return fs.list("proj")|)
      names = json |> Jason.decode!() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["src", "top.txt"]
    end

    test "list of a missing directory is nil", %{sandbox: s} do
      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.list("proj", "nope")|)
      assert missing?(gone)
    end

    test "exists reports files and implied directories", %{sandbox: s} do
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.exists("proj", "top.txt")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.exists("proj", "src")|)
      assert {:ok, "true"} = Sandbox.eval(s, ~S|return fs.exists("proj", "src/deep")|)
      assert {:ok, "false"} = Sandbox.eval(s, ~S|return fs.exists("proj", "nope")|)
    end

    test "stat reports type and size", %{sandbox: s} do
      assert {:ok, "1"} = Sandbox.eval(s, ~S|return fs.stat("proj", "top.txt").size|)
      assert {:ok, ~s("file")} = Sandbox.eval(s, ~S|return fs.stat("proj", "top.txt").type|)
      assert {:ok, ~s("dir")} = Sandbox.eval(s, ~S|return fs.stat("proj", "src").type|)

      assert {:ok, gone} = Sandbox.eval(s, ~S|return fs.stat("proj", "nope")|)
      assert missing?(gone)
    end
  end

  describe "grants and paths" do
    test "namespaces() lists the accessible areas", %{sandbox: s} do
      assert {:ok, "2"} = Sandbox.eval(s, ~S|return #fs.namespaces()|)
    end

    test "an ungranted namespace raises", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~S|return fs.read("secret", "x")|)
      assert msg =~ "not accessible"
    end

    test "path traversal is rejected", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~S|return fs.write("proj", "../escape", "x")|)
      assert msg =~ ".."
    end
  end
end
