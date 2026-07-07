defmodule Epix.Lua.GitApi do
  @moduledoc """
  Installs the `git` table into a Lua state: the agent's capability-scoped access
  to the host git repositories, backed by `Epix.Git`.

  The operator grants a set of named repositories (see `Epix.Session`). Every call
  takes a repo `name` as its first argument; the functions close over the granted
  set, so touching a repo the agent was not granted raises a Lua error — the same
  shape as `Epix.Lua.KvApi`'s namespace grants.

  Reads span the whole repo. **Writes** (`git.commit`, `git.create_branch`) are
  limited to the branches the operator marked writable for that repo (`:all`, an
  explicit list, or none — read-only by default), so the agent can read broadly
  but only advance branches it was handed.

  This table is installed only when at least one repo is granted *and* the `git`
  executable is available on the host (`Epix.Git.available?/0`); a deployment
  without `git` simply never sees it, and the system prompt omits it to match.
  """

  alias Epix.Git

  @typedoc "A granted repo: its bare git dir and the branches writable in it."
  @type repo :: %{dir: String.t(), writable: :all | [String.t()]}
  @type ctx :: %{repos: %{String.t() => repo()}}

  @doc "Installs `git.*` into the Lua state, bound to the granted repositories."
  @spec install(Lua.t(), ctx()) :: Lua.t()
  def install(%Lua{} = lua, %{repos: repos}) when is_map(repos) do
    lua
    |> Lua.set!(["git", "repos"], repos_fun(repos))
    |> Lua.set!(["git", "read"], read_fun(repos))
    |> Lua.set!(["git", "exists"], exists_fun(repos))
    |> Lua.set!(["git", "stat"], stat_fun(repos))
    |> Lua.set!(["git", "list"], list_fun(repos))
    |> Lua.set!(["git", "log"], log_fun(repos))
    |> Lua.set!(["git", "diff"], diff_fun(repos))
    |> Lua.set!(["git", "branches"], branches_fun(repos))
    |> Lua.set!(["git", "resolve"], resolve_fun(repos))
    |> Lua.set!(["git", "create_branch"], create_branch_fun(repos))
    |> Lua.set!(["git", "commit"], commit_fun(repos))
  end

  @doc """
  Normalizes operator repo specs into the internal grant map (or nil if none).

  Each spec is a map `%{name: string, dir: string, writable: writable}` where
  `writable` is `:all`, a list of branch names, or a single branch name (default
  none — read-only). Raises `ArgumentError` on a malformed spec.
  """
  @spec normalize(term()) :: %{String.t() => repo()} | nil
  def normalize(nil), do: nil
  def normalize([]), do: nil

  def normalize(specs) when is_list(specs) do
    map = Map.new(specs, &normalize_repo/1)
    if map == %{}, do: nil, else: map
  end

  defp normalize_repo(%{name: name, dir: dir} = spec) when is_binary(dir) do
    {to_string(name), %{dir: dir, writable: normalize_writable(Map.get(spec, :writable, []))}}
  end

  defp normalize_repo(other) do
    raise ArgumentError, "invalid git repo spec: #{inspect(other)} (need %{name:, dir:})"
  end

  defp normalize_writable(:all), do: :all
  defp normalize_writable(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_writable(branch) when is_binary(branch), do: [branch]

  defp normalize_writable(other),
    do:
      raise(ArgumentError, "invalid :writable #{inspect(other)} (use :all, a list, or a branch)")

  @doc "Renders the git API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    """
    - `git.repos()` — list the repositories you can access, each a table with
      `name` and `writable` (`true` for all branches, a list of branch names, or
      `false` for read-only).
    - `git.read(repo, rev, path)` — a file's bytes at a revision, or nil if absent.
    - `git.exists(repo, rev, path)` — true if a file or directory exists there.
    - `git.stat(repo, rev, path)` — `{type, size}` for a path, or nil.
    - `git.list(repo, rev[, path[, recursive]])` — directory entries, each with
      `name`, `path`, `type`, `mode`, `sha`, `size`.
    - `git.log(repo, rev[, limit[, path]])` — commits newest-first, each with
      `sha`, `author`, `email`, `date`, `message`.
    - `git.diff(repo, from, to[, path])` — unified diff between two revisions.
    - `git.branches(repo)` — local branches, each with `name` and `sha`.
    - `git.resolve(repo, rev)` — resolve a revspec to a full sha, or nil.
    - `git.create_branch(repo, branch, from_rev)` — create a branch (writable only).
    - `git.commit(repo, branch, changes, message)` — apply an ordered change-set as
      one commit on a writable branch, returning the new sha. `changes` is a list of
      op tables: `{op="put", path=, content=}`, `{op="rm", path=}`,
      `{op="mv", from=, to=}`, `{op="cp", from=, to=}`. Later changes see earlier
      ones. A concurrent write raises a conflict — re-read and retry.

    A `rev` is any git revspec (a branch, tag, sha, or `HEAD~2`). Reads span the
    whole repo; writes are limited to the branches granted for that repo. Accessing
    a repo you were not granted raises an error; call `git.repos()` to see them.
    """
  end

  # --- functions -----------------------------------------------------------

  defp repos_fun(repos) do
    fn _args, lua ->
      summary =
        repos
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {name, %{writable: writable}} ->
          %{"name" => name, "writable" => writable_summary(writable)}
        end)

      encode(lua, summary)
    end
  end

  defp writable_summary(:all), do: true
  defp writable_summary([]), do: false
  defp writable_summary(list), do: list

  defp read_fun(repos) do
    fn
      [name, rev, path], lua when is_binary(rev) and is_binary(path) ->
        %{dir: dir} = repo!(repos, name)

        case Git.read(dir, rev, path) do
          {:ok, bytes} -> {[bytes], lua}
          {:error, _} -> {[nil], lua}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.read expects (repo, rev, path)"
    end
  end

  defp exists_fun(repos) do
    fn
      [name, rev, path], lua when is_binary(rev) and is_binary(path) ->
        %{dir: dir} = repo!(repos, name)
        {[Git.exists?(dir, rev, path)], lua}

      _args, _lua ->
        raise Lua.RuntimeException, "git.exists expects (repo, rev, path)"
    end
  end

  defp stat_fun(repos) do
    fn
      [name, rev, path], lua when is_binary(rev) and is_binary(path) ->
        %{dir: dir} = repo!(repos, name)

        case Git.stat(dir, rev, path) do
          {:ok, %{type: type, size: size}} ->
            encode(lua, %{"type" => to_string(type), "size" => size})

          {:error, _} ->
            {[nil], lua}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.stat expects (repo, rev, path)"
    end
  end

  defp list_fun(repos) do
    fn
      [name, rev], lua when is_binary(rev) ->
        do_list(repos, lua, name, rev, "", [])

      [name, rev, path], lua when is_binary(rev) and is_binary(path) ->
        do_list(repos, lua, name, rev, path, [])

      [name, rev, path, recursive], lua when is_binary(rev) and is_binary(path) ->
        do_list(repos, lua, name, rev, path, recursive: truthy(recursive))

      _args, _lua ->
        raise Lua.RuntimeException, "git.list expects (repo, rev[, path[, recursive]])"
    end
  end

  defp do_list(repos, lua, name, rev, path, opts) do
    %{dir: dir} = repo!(repos, name)

    case Git.list(dir, rev, path, opts) do
      {:ok, entries} -> encode(lua, Enum.map(entries, &entry_table/1))
      {:error, _} -> {[nil], lua}
    end
  end

  defp entry_table(entry) do
    %{
      "name" => entry.name,
      "path" => entry.path,
      "type" => to_string(entry.type),
      "mode" => entry.mode,
      "sha" => entry.sha,
      "size" => entry.size
    }
  end

  defp log_fun(repos) do
    fn
      [name, rev], lua when is_binary(rev) ->
        do_log(repos, lua, name, rev, [])

      [name, rev, limit], lua when is_binary(rev) and is_number(limit) ->
        do_log(repos, lua, name, rev, limit: trunc(limit))

      [name, rev, limit, path], lua
      when is_binary(rev) and is_number(limit) and is_binary(path) ->
        do_log(repos, lua, name, rev, limit: trunc(limit), path: path)

      _args, _lua ->
        raise Lua.RuntimeException, "git.log expects (repo, rev[, limit[, path]])"
    end
  end

  defp do_log(repos, lua, name, rev, opts) do
    %{dir: dir} = repo!(repos, name)

    case Git.log(dir, rev, opts) do
      {:ok, commits} -> encode(lua, Enum.map(commits, &commit_table/1))
      {:error, _} -> {[nil], lua}
    end
  end

  defp commit_table(commit) do
    %{
      "sha" => commit.sha,
      "author" => commit.author,
      "email" => commit.email,
      "date" => commit.date,
      "message" => commit.message
    }
  end

  defp diff_fun(repos) do
    fn
      [name, from, to], lua when is_binary(from) and is_binary(to) ->
        do_diff(repos, lua, name, from, to, [])

      [name, from, to, path], lua when is_binary(from) and is_binary(to) and is_binary(path) ->
        do_diff(repos, lua, name, from, to, path: path)

      _args, _lua ->
        raise Lua.RuntimeException, "git.diff expects (repo, from, to[, path])"
    end
  end

  defp do_diff(repos, lua, name, from, to, opts) do
    %{dir: dir} = repo!(repos, name)

    case Git.diff(dir, from, to, opts) do
      {:ok, diff} -> {[diff], lua}
      {:error, reason} -> raise Lua.RuntimeException, "git.diff failed: " <> reason_text(reason)
    end
  end

  defp branches_fun(repos) do
    fn
      [name], lua ->
        %{dir: dir} = repo!(repos, name)

        case Git.branches(dir) do
          {:ok, branches} ->
            encode(lua, Enum.map(branches, &%{"name" => &1.name, "sha" => &1.sha}))

          {:error, reason} ->
            raise Lua.RuntimeException, "git.branches failed: " <> reason_text(reason)
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.branches expects (repo)"
    end
  end

  defp resolve_fun(repos) do
    fn
      [name, rev], lua when is_binary(rev) ->
        %{dir: dir} = repo!(repos, name)

        case Git.resolve(dir, rev) do
          {:ok, sha} -> {[sha], lua}
          {:error, _} -> {[nil], lua}
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.resolve expects (repo, rev)"
    end
  end

  defp create_branch_fun(repos) do
    fn
      [name, branch, from_rev], lua when is_binary(branch) and is_binary(from_rev) ->
        repo = repo!(repos, name)
        writable!(repo, branch)

        case Git.create_branch(repo.dir, branch, from_rev) do
          {:ok, sha} ->
            {[sha], lua}

          {:error, :exists} ->
            raise Lua.RuntimeException, "git.create_branch: #{inspect(branch)} already exists"

          {:error, :not_found} ->
            raise Lua.RuntimeException, "git.create_branch: cannot resolve #{inspect(from_rev)}"
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.create_branch expects (repo, branch, from_rev)"
    end
  end

  defp commit_fun(repos) do
    fn
      [name, branch, changes, message], lua when is_binary(branch) and is_binary(message) ->
        repo = repo!(repos, name)
        writable!(repo, branch)

        case Git.commit(repo.dir, branch, to_changes(lua, changes), message) do
          {:ok, sha} ->
            {[sha], lua}

          {:error, :conflict} ->
            raise Lua.RuntimeException,
                  "git.commit: #{branch} advanced concurrently; re-read and retry"

          {:error, :nothing_to_commit} ->
            raise Lua.RuntimeException, "git.commit: the change-set is empty (nothing to commit)"

          {:error, :not_found} ->
            raise Lua.RuntimeException, "git.commit: a change referenced a missing source path"

          {:error, reason} ->
            raise Lua.RuntimeException, "git.commit failed: " <> reason_text(reason)
        end

      _args, _lua ->
        raise Lua.RuntimeException, "git.commit expects (repo, branch, changes, message)"
    end
  end

  # --- helpers -------------------------------------------------------------

  # Raises a Lua error unless `name` is a granted repo; returns its grant otherwise.
  defp repo!(repos, name) when is_binary(name) do
    case Map.fetch(repos, name) do
      {:ok, repo} -> repo
      :error -> raise Lua.RuntimeException, "repo #{inspect(name)} is not accessible"
    end
  end

  defp repo!(_repos, _name), do: raise(Lua.RuntimeException, "repo must be a string")

  defp writable!(repo, branch) do
    unless writable?(repo, branch) do
      raise Lua.RuntimeException, "branch #{inspect(branch)} is not writable in this repo"
    end

    :ok
  end

  defp writable?(%{writable: :all}, _branch), do: true
  defp writable?(%{writable: list}, branch), do: branch in list

  # Only nil and false are falsy in Lua.
  defp truthy(false), do: false
  defp truthy(nil), do: false
  defp truthy(_value), do: true

  defp reason_text({:git, _status, message}), do: message
  defp reason_text(:git_unavailable), do: "git is unavailable"
  defp reason_text(other), do: inspect(other)

  defp encode(lua, term) do
    {encoded, lua} = Lua.encode!(lua, term)
    {[encoded], lua}
  end

  # Decodes the Lua `changes` argument into an ordered list of `Epix.Git.change`s.
  defp to_changes(lua, changes) do
    case from_lua(Lua.decode!(lua, changes)) do
      empty when empty == %{} -> []
      list when is_list(list) -> Enum.map(list, &to_change/1)
      _other -> raise Lua.RuntimeException, "git.commit changes must be a list of change tables"
    end
  end

  defp to_change(%{"op" => op} = change), do: change(op, change)

  defp to_change(_other),
    do: raise(Lua.RuntimeException, "each change must be a table with an `op` field")

  defp change("put", %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content),
       do: {:put, path, content}

  defp change("rm", %{"path" => path}) when is_binary(path), do: {:rm, path}

  defp change("mv", %{"from" => from, "to" => to}) when is_binary(from) and is_binary(to),
    do: {:mv, from, to}

  defp change("cp", %{"from" => from, "to" => to}) when is_binary(from) and is_binary(to),
    do: {:cp, from, to}

  defp change(op, _fields) do
    raise Lua.RuntimeException,
          "invalid change for op #{inspect(op)} " <>
            "(fields: put→path,content; rm→path; mv/cp→from,to)"
  end

  # Turns `Lua.decode!` output (a table is a list of {key, value} pairs) into clean
  # Elixir data: an integer-sequence becomes a list, anything else a map. Mirrors
  # the decoding `Epix.Lua.KvApi` does for stored values.
  defp from_lua([]), do: %{}

  defp from_lua(pairs) when is_list(pairs) do
    cond do
      not Enum.all?(pairs, &match?({_, _}, &1)) -> pairs
      lua_sequence?(pairs) -> Enum.map(pairs, fn {_index, value} -> from_lua(value) end)
      true -> Map.new(pairs, fn {key, value} -> {key, from_lua(value)} end)
    end
  end

  defp from_lua(scalar), do: scalar

  defp lua_sequence?(pairs), do: Enum.map(pairs, &elem(&1, 0)) == Enum.to_list(1..length(pairs))
end
