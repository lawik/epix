defmodule Epix.Lua.FsApi do
  @moduledoc """
  Installs the `fs` table into a Lua state: the agent's virtual filesystem.

  Each granted namespace is a private file area, backed by one bare git repo per
  namespace under a host-configured root — but the agent is **none the wiser**. The
  surface is plain filesystem vocabulary (read, write, remove, move, list, exists,
  stat); there are no branches, commits, or shas here. A human can mount the same
  namespace with ordinary git tooling (`git --git-dir=<root>/<ns>.git log`, or a
  clone) to observe and interject.

  **A whole Lua run is one commit.** Every `fs.*` mutation in a single `lua_eval`
  or `lua_run_tool` accumulates in the VM's private state (with read-your-writes,
  so a later read sees an earlier write in the same run). When the run finishes
  successfully, `Epix.Lua.Runtime` calls `commit/2`, which lowers the accumulated
  changes into a single `Epix.Git.commit/5` on the namespace's default branch. If
  the run raises, nothing is committed — the changes are discarded with the VM.

  This is the "fs-pool" companion to `Epix.Lua.GitApi`'s "git-pool": the two lean
  on the same `Epix.Git` plumbing but are deliberately separate concepts, and an fs
  repo is never reachable through the `git` API.

  Access is gated by the same namespace grants as `Epix.Lua.KvApi`: a call to a
  namespace the agent does not currently hold raises a Lua error.
  """

  alias Epix.Git

  # Private key under which a run's pending changes ride along in the Lua VM:
  # %{namespace => %{path => {:put, binary} | :tombstone}}.
  @pending :fs_pending
  @branch "main"

  @type ctx :: %{root: String.t(), namespaces: [String.t()]}

  @doc "Installs `fs.*` into the Lua state, bound to a root dir and granted namespaces."
  @spec install(Lua.t(), ctx()) :: Lua.t()
  def install(%Lua{} = lua, %{root: root, namespaces: namespaces}) when is_binary(root) do
    lua
    |> Lua.set!(["fs", "namespaces"], namespaces_fun(namespaces))
    |> Lua.set!(["fs", "read"], read_fun(root, namespaces))
    |> Lua.set!(["fs", "write"], write_fun(namespaces))
    |> Lua.set!(["fs", "remove"], remove_fun(root, namespaces))
    |> Lua.set!(["fs", "move"], move_fun(root, namespaces))
    |> Lua.set!(["fs", "list"], list_fun(root, namespaces))
    |> Lua.set!(["fs", "exists"], exists_fun(root, namespaces))
    |> Lua.set!(["fs", "stat"], stat_fun(root, namespaces))
  end

  @doc "Normalizes the `:fs` option (a root dir string, or `[root: dir]`) into a config, or nil."
  @spec normalize(term()) :: %{root: String.t()} | nil
  def normalize(nil), do: nil
  def normalize(root) when is_binary(root), do: %{root: root}

  def normalize(opts) when is_list(opts) do
    case opts[:root] do
      root when is_binary(root) -> %{root: root}
      _ -> nil
    end
  end

  def normalize(_other), do: nil

  @doc "Renders the fs API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    """
    - `fs.namespaces()` — list the file areas (namespaces) you can access.
    - `fs.read(namespace, path)` — a file's contents as a string, or nil if absent.
    - `fs.write(namespace, path, content)` — create or overwrite a file. Parent
      directories are implicit. Returns true.
    - `fs.remove(namespace, path)` — delete a file, or a directory and everything
      under it. Returns true; errors if the path does not exist.
    - `fs.move(namespace, from, to)` — move/rename a file or directory. Returns true.
    - `fs.list(namespace[, path[, recursive]])` — list a directory (the root when
      `path` is omitted), each entry a table with `name`, `path`, `type`
      ("file"/"dir"), and `size`. Returns nil for a path that does not exist.
    - `fs.exists(namespace, path)` — true if a file or directory exists there.
    - `fs.stat(namespace, path)` — `{type, size}` for a path, or nil.

    Every call takes a `namespace`; accessing one you do not hold raises an error.
    Writes made during one run are saved together when the run finishes.
    """
  end

  # --- functions -----------------------------------------------------------

  defp namespaces_fun(namespaces) do
    fn _args, lua ->
      {encoded, lua} = Lua.encode!(lua, namespaces)
      {[encoded], lua}
    end
  end

  defp read_fun(root, namespaces) do
    fn
      [ns, path], lua when is_binary(path) ->
        check_access!(ns, namespaces)

        case merged_read(root, ns, overlay(lua, ns), norm(path)) do
          {:ok, bytes} -> {[bytes], lua}
          :not_found -> {[nil], lua}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "fs.read expects (namespace, path)"
    end
  end

  defp write_fun(namespaces) do
    fn
      [ns, path, content], lua when is_binary(path) and is_binary(content) ->
        check_access!(ns, namespaces)
        p = valid!(path)
        {[true], put_overlay(lua, ns, Map.put(overlay(lua, ns), p, {:put, content}))}

      [_ns, path, _content], _lua when is_binary(path) ->
        raise Lua.RuntimeException, "fs.write content must be a string"

      _args, _lua ->
        raise Lua.RuntimeException, "fs.write expects (namespace, path, content)"
    end
  end

  defp remove_fun(root, namespaces) do
    fn
      [ns, path], lua when is_binary(path) ->
        check_access!(ns, namespaces)
        ov = overlay(lua, ns)

        case targets(root, ns, ov, valid!(path)) do
          [] -> raise Lua.RuntimeException, "fs.remove: #{inspect(path)} does not exist"
          paths -> {[true], put_overlay(lua, ns, tombstone_all(ov, paths))}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "fs.remove expects (namespace, path)"
    end
  end

  defp move_fun(root, namespaces) do
    fn
      [ns, from, to], lua when is_binary(from) and is_binary(to) ->
        check_access!(ns, namespaces)
        src = valid!(from)
        dst = valid!(to)
        ov = overlay(lua, ns)

        case targets(root, ns, ov, src) do
          [] -> raise Lua.RuntimeException, "fs.move: #{inspect(from)} does not exist"
          paths -> {[true], put_overlay(lua, ns, relocate(root, ns, ov, paths, src, dst))}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "fs.move expects (namespace, from, to)"
    end
  end

  defp list_fun(root, namespaces) do
    fn
      [ns], lua ->
        do_list(root, ns, namespaces, lua, "", false)

      # `nil` path means the root — the model routinely passes it to reach the
      # recursive form, e.g. `fs.list(ns, nil, true)`.
      [ns, path], lua when is_binary(path) or is_nil(path) ->
        do_list(root, ns, namespaces, lua, path || "", false)

      [ns, path, recursive], lua when is_binary(path) or is_nil(path) ->
        do_list(root, ns, namespaces, lua, path || "", truthy(recursive))

      _args, _lua ->
        raise Lua.RuntimeException, "fs.list expects (namespace[, path[, recursive]])"
    end
  end

  defp do_list(root, ns, namespaces, lua, path, recursive) do
    check_access!(ns, namespaces)
    files = merged_files(root, ns, overlay(lua, ns))

    case entries(files, norm(path), recursive) do
      nil -> {[nil], lua}
      list -> encode(lua, list)
    end
  end

  defp exists_fun(root, namespaces) do
    fn
      [ns, path], lua when is_binary(path) ->
        check_access!(ns, namespaces)
        {[exists?(merged_files(root, ns, overlay(lua, ns)), norm(path))], lua}

      _args, _lua ->
        raise Lua.RuntimeException, "fs.exists expects (namespace, path)"
    end
  end

  defp stat_fun(root, namespaces) do
    fn
      [ns, path], lua when is_binary(path) ->
        check_access!(ns, namespaces)
        files = merged_files(root, ns, overlay(lua, ns))
        p = norm(path)

        cond do
          Map.has_key?(files, p) -> encode(lua, %{"type" => "file", "size" => files[p]})
          dir?(files, p) -> encode(lua, %{"type" => "dir", "size" => 0})
          true -> {[nil], lua}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "fs.stat expects (namespace, path)"
    end
  end

  # --- commit (called by Runtime after a successful run) -------------------

  @doc """
  Commits each namespace's accumulated run changes as a single commit.

  `pending` is the VM's `#{inspect(@pending)}` private map
  (`%{namespace => overlay}`). Returns `:ok`, or `{:error, message}` if a namespace
  could not be saved (surfaced to the model as the run's error).
  """
  @spec commit(String.t(), %{String.t() => map()}) :: :ok | {:error, String.t()}
  def commit(root, pending) when is_binary(root) and is_map(pending) do
    Enum.reduce_while(pending, :ok, fn {ns, overlay}, :ok ->
      case commit_namespace(root, ns, overlay) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Reads the pending-changes map out of a VM after a run (empty if none)."
  @spec pending(Lua.t()) :: %{String.t() => map()}
  def pending(%Lua{} = lua) do
    case Lua.get_private(lua, @pending) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp commit_namespace(_root, _ns, overlay) when overlay == %{}, do: :ok

  defp commit_namespace(root, ns, overlay) do
    dir = repo_dir(root, ns)

    case ensure_repo(dir) do
      :ok -> attempt_commit(dir, ns, overlay, 3)
      {:error, reason} -> {:error, save_error(ns, reason)}
    end
  end

  # Lowers the overlay against the *current* tip each attempt, so a lost
  # compare-and-swap can simply retry with a fresh base.
  defp attempt_commit(dir, ns, overlay, tries) do
    case lower(dir, overlay) do
      [] ->
        :ok

      changes ->
        case Git.commit(dir, @branch, changes, message(changes)) do
          {:ok, _sha} -> :ok
          {:error, :nothing_to_commit} -> :ok
          {:error, :conflict} when tries > 1 -> attempt_commit(dir, ns, overlay, tries - 1)
          {:error, reason} -> {:error, save_error(ns, reason)}
        end
    end
  end

  # An overlay entry becomes a put; a tombstone becomes a remove only if the path
  # is actually present in the base tree (removing an uncommitted path would abort
  # the whole commit as :not_found).
  defp lower(dir, overlay) do
    base = committed_files(dir)

    Enum.flat_map(overlay, fn
      {path, {:put, content}} -> [{:put, path, content}]
      {path, :tombstone} -> if Map.has_key?(base, path), do: [{:rm, path}], else: []
    end)
  end

  defp message(changes) do
    {puts, rms} = Enum.split_with(changes, &match?({:put, _, _}, &1))

    parts =
      [{length(puts), "written"}, {length(rms), "removed"}]
      |> Enum.reject(fn {n, _} -> n == 0 end)
      |> Enum.map_join(", ", fn {n, label} -> "#{n} #{label}" end)

    "fs: " <> parts
  end

  defp save_error(ns, reason),
    do:
      "filesystem changes for namespace #{inspect(ns)} could not be saved: #{reason_text(reason)}"

  defp reason_text({:git, _status, message}), do: message
  defp reason_text(:git_unavailable), do: "git is unavailable"
  defp reason_text(other), do: inspect(other)

  # --- merged view ---------------------------------------------------------

  # A run's-eye view of the namespace: committed files overlaid with pending puts
  # and tombstones, as %{path => size}.
  defp merged_files(root, ns, overlay) do
    base = committed_files(repo_dir(root, ns))

    Enum.reduce(overlay, base, fn
      {path, {:put, content}}, acc -> Map.put(acc, path, byte_size(content))
      {path, :tombstone}, acc -> Map.delete(acc, path)
    end)
  end

  defp merged_read(root, ns, overlay, path) do
    case Map.get(overlay, path) do
      {:put, content} -> {:ok, content}
      :tombstone -> :not_found
      nil -> committed_read(repo_dir(root, ns), path)
    end
  end

  # Files that a remove/move should act on: the path itself if it is a file, or
  # everything beneath it if it is a directory.
  defp targets(root, ns, overlay, path) do
    files = merged_files(root, ns, overlay)

    if Map.has_key?(files, path) do
      [path]
    else
      for {p, _size} <- files, under?(p, path), do: p
    end
  end

  defp tombstone_all(overlay, paths),
    do: Enum.reduce(paths, overlay, &Map.put(&2, &1, :tombstone))

  # Moves each source file to its destination (a single file, or every file under a
  # directory with its suffix preserved), reading content through the overlay so a
  # move sees writes made earlier in the same run.
  defp relocate(root, ns, overlay, paths, src, dst) do
    Enum.reduce(paths, overlay, fn path, acc ->
      {:ok, content} = merged_read(root, ns, acc, path)
      dest = dst <> String.replace_prefix(path, src, "")
      acc |> Map.put(dest, {:put, content}) |> Map.put(path, :tombstone)
    end)
  end

  defp entries(files, dir, recursive) do
    prefix = if dir == "", do: "", else: dir <> "/"

    beneath =
      for {path, size} <- files, prefix == "" or String.starts_with?(path, prefix) do
        {String.replace_prefix(path, prefix, ""), path, size}
      end

    cond do
      beneath != [] -> render_entries(beneath, prefix, recursive)
      dir == "" -> []
      true -> nil
    end
  end

  defp render_entries(beneath, _prefix, true) do
    Enum.map(beneath, fn {_rel, path, size} -> file_entry(path, size) end)
  end

  defp render_entries(beneath, prefix, false) do
    beneath
    |> Enum.map(fn {rel, path, size} ->
      case String.split(rel, "/", parts: 2) do
        [_file] -> file_entry(path, size)
        [dir, _rest] -> dir_entry(prefix <> dir)
      end
    end)
    |> Enum.uniq()
    |> Enum.sort_by(& &1["path"])
  end

  defp file_entry(path, size),
    do: %{"name" => Path.basename(path), "path" => path, "type" => "file", "size" => size}

  defp dir_entry(path),
    do: %{"name" => Path.basename(path), "path" => path, "type" => "dir", "size" => 0}

  defp exists?(files, path), do: Map.has_key?(files, path) or dir?(files, path)

  defp dir?(files, path), do: Enum.any?(files, fn {p, _size} -> under?(p, path) end)

  defp under?(path, dir), do: String.starts_with?(path, dir <> "/")

  # --- committed reads -----------------------------------------------------

  defp committed_read(dir, path) do
    if Git.repo?(dir) do
      case Git.read(dir, @branch, path) do
        {:ok, content} -> {:ok, content}
        {:error, _} -> :not_found
      end
    else
      :not_found
    end
  end

  defp committed_files(dir) do
    with true <- Git.repo?(dir),
         {:ok, entries} <- Git.list(dir, @branch, "", recursive: true) do
      Map.new(entries, &{&1.path, &1.size})
    else
      _ -> %{}
    end
  end

  # --- overlay plumbing (VM private state) ---------------------------------

  defp overlay(lua, ns), do: Map.get(pending(lua), ns, %{})

  defp put_overlay(lua, ns, overlay),
    do: Lua.put_private(lua, @pending, Map.put(pending(lua), ns, overlay))

  # --- helpers -------------------------------------------------------------

  defp ensure_repo(dir) do
    if Git.repo?(dir), do: :ok, else: Git.init(dir)
  end

  defp repo_dir(root, ns), do: Path.join(root, ns <> ".git")

  defp check_access!(ns, namespaces) when is_binary(ns) do
    unless ns in namespaces do
      raise Lua.RuntimeException, "namespace #{inspect(ns)} is not accessible"
    end

    :ok
  end

  defp check_access!(_ns, _namespaces),
    do: raise(Lua.RuntimeException, "namespace must be a string")

  # Normalizes a path to repo-relative form (matching how committed paths read back)
  # and rejects traversal, so overlay keys line up with the git tree.
  defp valid!(path) do
    p = norm(path)

    cond do
      p == "" -> raise Lua.RuntimeException, "path must not be empty"
      ".." in Path.split(p) -> raise Lua.RuntimeException, "path must not contain '..'"
      true -> p
    end
  end

  defp norm(path) do
    path
    |> String.trim()
    |> strip_leading()
    |> String.trim_trailing("/")
  end

  defp strip_leading("/" <> rest), do: strip_leading(rest)
  defp strip_leading("./" <> rest), do: strip_leading(rest)
  defp strip_leading(path), do: path

  defp truthy(false), do: false
  defp truthy(nil), do: false
  defp truthy(_value), do: true

  defp encode(lua, term) do
    {encoded, lua} = Lua.encode!(lua, term)
    {[encoded], lua}
  end
end
