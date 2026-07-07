defmodule Epix.Lua.Runtime do
  @moduledoc """
  Stateless Lua execution primitives.

  Every call builds a fresh sandboxed Lua VM with the sandbox APIs installed, so
  runs are isolated from each other. Durable state (the registry of defined tools)
  lives in `Epix.Lua.Sandbox`; this module only knows how to compile and run.

  Results and errors are returned as strings ready to hand back to the model.
  """

  alias Epix.Lua.{BytesApi, FsApi, GitApi, KvApi, TimeApi, WebApi}

  @type result :: {:ok, String.t()} | {:error, String.t()}
  # nil = nothing beyond `time`; otherwise the optionally-present `kv` (store +
  # granted namespaces), `web` (Kagi options), `git` (granted repos), and `fs`
  # (per-namespace file areas) capabilities for this run.
  @type ctx ::
          nil
          | %{
              store: Epix.Store.t() | nil,
              namespaces: [String.t()],
              web: keyword() | nil,
              git: %{String.t() => GitApi.repo()} | nil,
              fs: %{root: String.t()} | nil
            }

  @doc "Evaluates a one-shot Lua snippet. Use `return X` to produce a result."
  @spec eval(String.t(), ctx()) :: result()
  def eval(code, ctx \\ nil) when is_binary(code) do
    run(ctx, fn -> Lua.eval!(build(ctx), code) end)
  end

  @doc """
  Validates that a tool body compiles, given its parameter names.

  Only checks syntax (compile time). References to undefined host functions are
  runtime errors and surface when the tool is run.
  """
  @spec validate_tool([String.t()], String.t()) :: :ok | {:error, String.t()}
  def validate_tool(params, code) when is_list(params) and is_binary(code) do
    script = wrap(params, code) <> "\nreturn true"

    case run(nil, fn -> Lua.eval!(build(nil), script) end) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc "Runs a stored tool body with the given argument map (string keys)."
  @spec run_tool([String.t()], String.t(), map(), ctx()) :: result()
  def run_tool(params, code, args, ctx \\ nil)
      when is_list(params) and is_binary(code) and is_map(args) do
    lua =
      Enum.reduce(params, build(ctx), fn p, acc ->
        Lua.set!(acc, ["__args", p], Map.get(args, p))
      end)

    call = Enum.map_join(params, ", ", fn p -> "__args.#{p}" end)
    script = wrap(params, code) <> "return __tool(#{call})"
    run(ctx, fn -> Lua.eval!(lua, script) end)
  end

  defp build(nil), do: Lua.new() |> TimeApi.install() |> BytesApi.install()

  defp build(ctx) when is_map(ctx) do
    Lua.new()
    |> TimeApi.install()
    |> BytesApi.install()
    |> maybe_install_kv(ctx)
    |> maybe_install_web(ctx)
    |> maybe_install_git(ctx)
    |> maybe_install_fs(ctx)
  end

  defp maybe_install_kv(lua, %{store: store, namespaces: namespaces}) when not is_nil(store),
    do: KvApi.install(lua, %{store: store, namespaces: namespaces})

  defp maybe_install_kv(lua, _ctx), do: lua

  defp maybe_install_web(lua, %{web: opts}) when is_list(opts), do: WebApi.install(lua, opts)
  defp maybe_install_web(lua, _ctx), do: lua

  # Installed only when repos are granted *and* the host has `git`; otherwise the
  # capability silently degrades (the system prompt omits it to match).
  defp maybe_install_git(lua, %{git: repos}) when is_map(repos) and map_size(repos) > 0 do
    if Epix.Git.available?(), do: GitApi.install(lua, %{repos: repos}), else: lua
  end

  defp maybe_install_git(lua, _ctx), do: lua

  # Like git, fs is backed by `Epix.Git`, so it is installed only when a root is
  # configured *and* the host has `git`; otherwise it silently degrades.
  defp maybe_install_fs(lua, %{fs: %{root: root}, namespaces: namespaces}) when is_binary(root) do
    if Epix.Git.available?(),
      do: FsApi.install(lua, %{root: root, namespaces: namespaces}),
      else: lua
  end

  defp maybe_install_fs(lua, _ctx), do: lua

  defp wrap(params, code) do
    "local function __tool(#{Enum.join(params, ", ")})\n#{code}\nend\n"
  end

  # A whole run is one commit: on success, the fs changes accumulated in the VM's
  # private state are persisted; a raised run commits nothing (they die with the VM).
  defp run(ctx, fun) do
    {results, lua} = fun.()

    case commit_fs(ctx, lua) do
      :ok -> {:ok, format(results)}
      {:error, message} -> {:error, message}
    end
  rescue
    # Lua compile/runtime errors are useful to the model, so surface them. Any
    # other exception (e.g. a host FunctionClauseError) would leak Elixir module
    # paths/internals, so report it generically.
    e in [Lua.CompilerException, Lua.RuntimeException] -> {:error, Exception.message(e)}
    _other -> {:error, "Lua evaluation failed"}
  end

  defp commit_fs(%{fs: %{root: root}}, lua) when is_binary(root),
    do: FsApi.commit(root, FsApi.pending(lua))

  defp commit_fs(_ctx, _lua), do: :ok

  defp format([]), do: "nil"
  defp format([value]), do: format_value(value)
  defp format(values), do: "[" <> Enum.map_join(values, ", ", &format_value/1) <> "]"

  defp format_value(value) do
    case Jason.encode(jsonable(value)) do
      {:ok, json} ->
        json

      # Never inspect/1 the value: Luerl function refs, closures, and raw binaries
      # leak Erlang/Elixir internals to the model. Return a neutral placeholder that
      # points at the escape hatch for the common case (binary data).
      {:error, _} ->
        "<value is not text; if it is binary, view it with bytes.hex/base64/hexdump>"
    end
  end

  # Luerl decodes a returned Lua table to a list of {key, value} pairs, which Jason
  # cannot encode. Turn an integer-sequence into a list and any other table into a
  # map so a `return {…}` reaches the model as clean JSON rather than a placeholder.
  defp jsonable([]), do: %{}

  defp jsonable(pairs) when is_list(pairs) do
    cond do
      not Enum.all?(pairs, &match?({_, _}, &1)) -> Enum.map(pairs, &jsonable/1)
      sequence?(pairs) -> Enum.map(pairs, fn {_index, value} -> jsonable(value) end)
      true -> Map.new(pairs, fn {key, value} -> {jsonable_key(key), jsonable(value)} end)
    end
  end

  defp jsonable(scalar), do: scalar

  defp sequence?(pairs), do: Enum.map(pairs, &elem(&1, 0)) == Enum.to_list(1..length(pairs))

  # JSON object keys must be strings; Lua's numeric keys become their string form.
  defp jsonable_key(key) when is_binary(key), do: key
  defp jsonable_key(key), do: to_string(key)
end
