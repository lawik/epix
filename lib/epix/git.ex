defmodule Epix.Git do
  @moduledoc """
  Headless git plumbing over a **bare** repository — no worktree, no checkout.

  This is the storage primitive both higher-level Lua APIs lean on, kept
  deliberately ignorant of *policy* (namespaces, grants, capability checks live
  one layer up):

    * the **fs-pool** — one repo per namespace, where a whole Lua run is bundled
      into a single `commit/5` on the default branch; and
    * the **git-pool** — repos the user offers, where the agent reads across the
      whole repo and commits explicitly onto granted branches.

  Every "file operation" is an object-database operation: a write is a blob, a
  set of changes becomes a tree, a tree becomes a commit, and a branch is moved
  to point at it. Nothing is ever checked out, so a human can keep an ordinary
  clone of the same repo and use their normal tools.

  The centerpiece is `commit/5`: it applies an ordered change-set against a base
  commit and advances a branch ref with a **compare-and-swap** (the old value
  must still match), so a concurrent writer is detected as `{:error, :conflict}`
  rather than silently clobbered.

  All commands run with the host's global/system git config neutralized, so the
  repo behaves identically regardless of the operator's `~/.gitconfig`.

  Destructive operations (force-update, branch deletion, history rewriting) and
  remote operations (fetch/push) are intentionally **not** implemented here yet;
  they will arrive behind their own explicit grants.

  This layer shells out to the `git` executable. On a host where `git` is not on
  the `PATH`, commands return `{:error, :git_unavailable}` rather than raising, so
  a deployment without `git` degrades cleanly instead of crashing. Use
  `available?/0` to decide up front whether to offer the capability at all.
  """

  # The well-known empty-tree object and the all-zero OID ("ref must not exist"
  # sentinel for compare-and-swap ref creation).
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  @zero_oid "0000000000000000000000000000000000000000"

  @default_branch "main"
  @default_name "epix"
  @default_email "epix@localhost"

  # Neutralize the operator's git config so behavior is hermetic and the agent
  # cannot inherit host filters/hooks/aliases.
  @base_env [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

  @type git_dir :: String.t()
  @type sha :: String.t()
  @type rev :: String.t()
  @type branch :: String.t()

  @type identity :: %{
          optional(:name) => String.t(),
          optional(:email) => String.t(),
          optional(:date) => String.t()
        }

  @typedoc "An ordered file operation applied within a single commit."
  @type change ::
          {:put, String.t(), binary()}
          | {:rm, String.t()}
          | {:mv, String.t(), String.t()}
          | {:cp, String.t(), String.t()}

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: :file | :dir | :submodule,
          mode: String.t(),
          sha: sha(),
          size: non_neg_integer() | nil
        }

  @type commit_info :: %{
          sha: sha(),
          author: String.t(),
          email: String.t(),
          date: String.t(),
          message: String.t()
        }

  @type error :: {:git, non_neg_integer(), String.t()} | :git_unavailable

  # --- availability --------------------------------------------------------

  @doc """
  Returns true if the `git` executable is available on the host `PATH`.

  Cheap to call; the host uses this to decide whether to offer the git capability
  at all (see `Epix.Lua.GitApi`), so a deployment without `git` simply omits it.
  """
  @spec available?() :: boolean()
  def available?(), do: System.find_executable("git") != nil

  # --- repository lifecycle ------------------------------------------------

  @doc """
  Creates a bare repository at `git_dir` with `HEAD` on the default branch.

  Options:
    * `:default_branch` — the initial branch name (default `"main"`).
  """
  @spec init(git_dir(), keyword()) :: :ok | {:error, error()}
  def init(git_dir, opts \\ []) do
    branch = Keyword.get(opts, :default_branch, @default_branch)

    case cmd(["init", "--bare", "-b", branch, git_dir], []) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:git, status, String.trim(out)}}
      :unavailable -> {:error, :git_unavailable}
    end
  end

  @doc "Returns true if `git_dir` is a usable git repository."
  @spec repo?(git_dir()) :: boolean()
  def repo?(git_dir) do
    File.dir?(git_dir) and match?({:ok, _}, git(git_dir, ["rev-parse", "--git-dir"]))
  end

  # --- reads ---------------------------------------------------------------

  @doc "Resolves a revspec (branch, tag, sha, `HEAD~2`, …) to a full object id."
  @spec resolve(git_dir(), rev()) :: {:ok, sha()} | {:error, :not_found}
  def resolve(git_dir, revspec) do
    case git(git_dir, ["rev-parse", "--verify", "--quiet", revspec]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Lists local branches with their tip object ids."
  @spec branches(git_dir()) :: {:ok, [%{name: branch(), sha: sha()}]} | {:error, error()}
  def branches(git_dir) do
    case git(git_dir, ["for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads/"]) do
      {:ok, out} -> {:ok, parse_branches(out)}
      err -> err
    end
  end

  @doc "Reads a file's bytes at `rev`, or `{:error, :not_found}` if absent or not a file."
  @spec read(git_dir(), rev(), String.t()) :: {:ok, binary()} | {:error, :not_found}
  def read(git_dir, rev, path) do
    case git(git_dir, ["cat-file", "blob", object(rev, path)]) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Returns true if a file or directory exists at `rev`/`path`."
  @spec exists?(git_dir(), rev(), String.t()) :: boolean()
  def exists?(git_dir, rev, path) do
    match?({:ok, _}, git(git_dir, ["cat-file", "-e", object(rev, path)]))
  end

  @doc "Returns `{:ok, %{type:, size:}}` for a path at `rev`, or `{:error, :not_found}`."
  @spec stat(git_dir(), rev(), String.t()) ::
          {:ok, %{type: :file | :dir, size: non_neg_integer()}} | {:error, :not_found}
  def stat(git_dir, rev, path) do
    spec = object(rev, path)

    with {:ok, type} <- git(git_dir, ["cat-file", "-t", spec]),
         {:ok, size} <- git(git_dir, ["cat-file", "-s", spec]) do
      {:ok, %{type: object_type(String.trim(type)), size: String.to_integer(String.trim(size))}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Lists the entries of a directory at `rev` (root when `path` is empty).

  Names are relative to the listed directory; `:path` is the repo-root-relative
  path. Options:
    * `:recursive` — descend into subdirectories (default `false`).
  """
  @spec list(git_dir(), rev(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, :not_found}
  def list(git_dir, rev, path \\ "", opts \\ []) do
    base = normalize(path)
    treeish = if base == "", do: rev, else: object(rev, base)
    args = ["ls-tree", "--long"] ++ recursive_flag(opts) ++ [treeish]

    case git(git_dir, args) do
      {:ok, out} -> {:ok, parse_entries(out, base)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Returns commit history reachable from `rev`, newest first.

  Options:
    * `:limit` — cap the number of commits.
    * `:path` — only commits touching this path.
  """
  @spec log(git_dir(), rev(), keyword()) :: {:ok, [commit_info()]} | {:error, :not_found}
  def log(git_dir, rev, opts \\ []) do
    args =
      ["log", "--format=" <> log_format()] ++
        limit_flag(opts) ++ [rev] ++ path_filter(opts)

    case git(git_dir, args) do
      {:ok, out} -> {:ok, parse_log(out)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Returns the unified diff between two revs, optionally limited to `:path`."
  @spec diff(git_dir(), rev(), rev(), keyword()) :: {:ok, binary()} | {:error, error()}
  def diff(git_dir, from, to, opts \\ []) do
    git(git_dir, ["diff", from, to] ++ path_filter(opts))
  end

  # --- writes --------------------------------------------------------------

  @doc """
  Applies an ordered change-set as a single commit and advances `branch`.

  Changes are applied in order against a base tree (so later changes see earlier
  ones — read-your-writes within the commit). The branch ref is moved with a
  compare-and-swap against the base, so a concurrent move yields
  `{:error, :conflict}`.

  Options:
    * `:base` — the commit to build on (defaults to the branch's current tip, or
      a root commit if the branch does not yet exist).
    * `:author` / `:committer` — `t:identity/0` maps (committer defaults to author).
    * `:allow_empty` — commit even when the tree is unchanged (default `false`).

  Returns the new commit id, `{:error, :conflict}` on a lost compare-and-swap,
  `{:error, :nothing_to_commit}` when nothing changed, or `{:error, :not_found}`
  when a change references a missing source path.
  """
  @spec commit(git_dir(), branch(), [change()], String.t(), keyword()) ::
          {:ok, sha()}
          | {:error, :conflict | :nothing_to_commit | :not_found | error()}
  def commit(git_dir, branch, changes, message, opts \\ []) do
    base = Keyword.get_lazy(opts, :base, fn -> current_tip(git_dir, branch) end)
    tmp = mktemp()

    ctx = %{
      index: Path.join(tmp, "index"),
      blob: Path.join(tmp, "blob"),
      work: Path.join(tmp, "work")
    }

    File.mkdir_p!(ctx.work)

    try do
      with :ok <- make_index(git_dir, ctx, base),
           :ok <- apply_changes(git_dir, ctx, changes),
           {:ok, tree} <- write_tree(git_dir, ctx),
           :ok <- changed?(git_dir, base, tree, opts),
           {:ok, sha} <- commit_tree(git_dir, tree, base, message, opts),
           :ok <- update_ref(git_dir, "refs/heads/" <> branch, sha, base) do
        {:ok, sha}
      end
    after
      File.rm_rf(tmp)
    end
  end

  @doc """
  Creates `name` pointing at `from_rev` without checking it out.

  Returns `{:error, :exists}` if the branch already exists, or
  `{:error, :not_found}` if `from_rev` cannot be resolved.
  """
  @spec create_branch(git_dir(), branch(), rev()) ::
          {:ok, sha()} | {:error, :exists | :not_found}
  def create_branch(git_dir, name, from_rev) do
    with {:ok, sha} <- resolve(git_dir, from_rev),
         {:ok, _} <- git(git_dir, ["update-ref", "refs/heads/" <> name, sha, @zero_oid]) do
      {:ok, sha}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :exists}
    end
  end

  # --- commit internals ----------------------------------------------------

  defp make_index(git_dir, ctx, nil), do: ok(git_index(git_dir, ctx, ["read-tree", "--empty"]))
  defp make_index(git_dir, ctx, base), do: ok(git_index(git_dir, ctx, ["read-tree", base]))

  defp apply_changes(_git_dir, _ctx, []), do: :ok

  defp apply_changes(git_dir, ctx, [change | rest]) do
    case apply_one(git_dir, ctx, change) do
      :ok -> apply_changes(git_dir, ctx, rest)
      {:error, _} = err -> err
    end
  end

  defp apply_one(git_dir, ctx, {:put, path, content}) do
    File.write!(ctx.blob, content)

    with {:ok, sha} <- git(git_dir, ["hash-object", "-w", "--no-filters", ctx.blob]) do
      ok(cacheinfo(git_dir, ctx, "100644", String.trim(sha), path))
    end
  end

  defp apply_one(git_dir, ctx, {:rm, path}) do
    with {:ok, _mode, _sha} <- staged(git_dir, ctx, path) do
      ok(git_index(git_dir, ctx, ["update-index", "--force-remove", normalize(path)]))
    end
  end

  defp apply_one(git_dir, ctx, {:mv, from, to}) do
    with {:ok, mode, sha} <- staged(git_dir, ctx, from),
         {:ok, _} <- cacheinfo(git_dir, ctx, mode, sha, to),
         {:ok, _} <- git_index(git_dir, ctx, ["update-index", "--force-remove", normalize(from)]) do
      :ok
    end
  end

  defp apply_one(git_dir, ctx, {:cp, from, to}) do
    with {:ok, mode, sha} <- staged(git_dir, ctx, from) do
      ok(cacheinfo(git_dir, ctx, mode, sha, to))
    end
  end

  # Looks up a path's mode + object id in the staging index.
  defp staged(git_dir, ctx, path) do
    case git_index(git_dir, ctx, ["ls-files", "--stage", "--", normalize(path)]) do
      {:ok, ""} ->
        {:error, :not_found}

      {:ok, out} ->
        [meta | _] = String.split(out, "\n", trim: true)
        [info, _name] = String.split(meta, "\t", parts: 2)
        [mode, sha, _stage] = String.split(info)
        {:ok, mode, sha}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp cacheinfo(git_dir, ctx, mode, sha, path) do
    git_index(git_dir, ctx, [
      "update-index",
      "--add",
      "--cacheinfo",
      "#{mode},#{sha},#{normalize(path)}"
    ])
  end

  defp write_tree(git_dir, ctx) do
    case git_index(git_dir, ctx, ["write-tree"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      err -> err
    end
  end

  defp changed?(git_dir, base, tree, opts) do
    if Keyword.get(opts, :allow_empty, false) or tree != base_tree(git_dir, base) do
      :ok
    else
      {:error, :nothing_to_commit}
    end
  end

  defp base_tree(_git_dir, nil), do: @empty_tree

  defp base_tree(git_dir, base) do
    case resolve(git_dir, base <> "^{tree}") do
      {:ok, tree} -> tree
      _ -> nil
    end
  end

  defp commit_tree(git_dir, tree, base, message, opts) do
    args = ["commit-tree", tree] ++ parent_flag(base) ++ ["-m", message]

    case git(git_dir, args, identity_env(opts)) do
      {:ok, out} -> {:ok, String.trim(out)}
      err -> err
    end
  end

  defp parent_flag(nil), do: []
  defp parent_flag(base), do: ["-p", base]

  # Compare-and-swap the branch ref: the update only lands if the ref is still at
  # `base` (or absent, when creating). A lost race surfaces as :conflict.
  defp update_ref(git_dir, ref, new, base) do
    case git(git_dir, ["update-ref", ref, new, base || @zero_oid]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :conflict}
    end
  end

  defp current_tip(git_dir, branch) do
    case resolve(git_dir, "refs/heads/" <> branch) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp identity_env(opts) do
    author = Keyword.get(opts, :author, %{})
    committer = Keyword.get(opts, :committer, author)
    ident_env(author, "GIT_AUTHOR") ++ ident_env(committer, "GIT_COMMITTER")
  end

  defp ident_env(identity, prefix) do
    base = [
      {prefix <> "_NAME", Map.get(identity, :name, @default_name)},
      {prefix <> "_EMAIL", Map.get(identity, :email, @default_email)}
    ]

    case Map.get(identity, :date) do
      nil -> base
      date -> base ++ [{prefix <> "_DATE", date}]
    end
  end

  # --- parsing -------------------------------------------------------------

  defp parse_branches(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, sha] = String.split(line, " ", parts: 2)
      %{name: name, sha: sha}
    end)
  end

  defp parse_entries(out, base) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_entry(&1, base))
  end

  defp parse_entry(line, base) do
    [meta, name] = String.split(line, "\t", parts: 2)
    [mode, type, sha, size] = String.split(meta)

    %{
      name: Path.basename(name),
      path: join_path(base, name),
      type: tree_type(type),
      mode: mode,
      sha: sha,
      size: parse_size(size)
    }
  end

  defp join_path("", name), do: name
  defp join_path(base, name), do: base <> "/" <> name

  defp tree_type("blob"), do: :file
  defp tree_type("tree"), do: :dir
  defp tree_type("commit"), do: :submodule

  defp object_type("blob"), do: :file
  defp object_type("tree"), do: :dir

  defp parse_size("-"), do: nil
  defp parse_size(size), do: String.to_integer(size)

  # Unit-separated fields, record-separated commits, raw body last.
  defp log_format(), do: "%H%x1f%an%x1f%ae%x1f%aI%x1f%B%x1e"

  defp parse_log(out) do
    out
    |> String.split("\x1e")
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_commit/1)
  end

  defp parse_commit(record) do
    [sha, author, email, date, body] = String.split(record, "\x1f")

    %{
      sha: sha,
      author: author,
      email: email,
      date: date,
      message: String.trim_trailing(body)
    }
  end

  # --- command plumbing ----------------------------------------------------

  defp mktemp() do
    dir = Path.join(System.tmp_dir!(), "epix-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # Index operations (notably `--force-remove`) insist on a work tree, so we hand
  # them an empty scratch one and flip `core.bare` off for just these calls. No
  # checkout ever happens, so the scratch tree stays empty.
  defp git_index(git_dir, ctx, args) do
    git(git_dir, args, [
      {"GIT_INDEX_FILE", ctx.index},
      {"GIT_WORK_TREE", ctx.work},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "core.bare"},
      {"GIT_CONFIG_VALUE_0", "false"}
    ])
  end

  defp git(git_dir, args, env \\ []) do
    case cmd(["--git-dir", git_dir | args], env) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git, status, String.trim(out)}}
      :unavailable -> {:error, :git_unavailable}
    end
  end

  # Runs `git` with host config neutralized. Returns the raw `{output, status}`,
  # or `:unavailable` when the `git` binary is missing — `System.cmd/3` raises
  # `:enoent` in that case, and we would rather report a clean error than crash.
  defp cmd(args, env) do
    System.cmd("git", args, env: @base_env ++ env, stderr_to_stdout: true)
  rescue
    e in ErlangError ->
      if e.original == :enoent, do: :unavailable, else: reraise(e, __STACKTRACE__)
  end

  # `<rev>:<path>` peels a rev to the object at that path; empty path is the root.
  defp object(rev, path), do: rev <> ":" <> normalize(path)

  defp normalize(path) do
    path
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp recursive_flag(opts), do: if(Keyword.get(opts, :recursive, false), do: ["-r"], else: [])
  defp limit_flag(opts), do: opt_arg(opts, :limit, fn n -> ["-n", Integer.to_string(n)] end)
  defp path_filter(opts), do: opt_arg(opts, :path, fn p -> ["--", normalize(p)] end)

  defp opt_arg(opts, key, fun) do
    case Keyword.get(opts, key) do
      nil -> []
      value -> fun.(value)
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other
end
