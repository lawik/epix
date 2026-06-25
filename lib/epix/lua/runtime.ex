defmodule Epix.Lua.Runtime do
  @moduledoc """
  Stateless Lua execution primitives.

  Every call builds a fresh sandboxed Lua VM with the host API installed, so runs
  are isolated from each other. Durable state (the registry of defined tools)
  lives in `Epix.Lua.Sandbox`; this module only knows how to compile and run.

  Results and errors are returned as strings ready to hand back to the model.
  """

  alias Epix.Lua.{HostApi, StoreApi}

  @type result :: {:ok, String.t()} | {:error, String.t()}
  # nil = no storage; otherwise the store + granted namespaces for the `store` API.
  @type ctx :: nil | StoreApi.ctx()

  @doc "Evaluates a one-shot Lua snippet. Use `return X` to produce a result."
  @spec eval(String.t(), ctx()) :: result()
  def eval(code, ctx \\ nil) when is_binary(code) do
    run(fn -> Lua.eval!(build(ctx), code) end)
  end

  @doc """
  Validates that a tool body compiles, given its parameter names.

  Only checks syntax (compile time). References to undefined host functions are
  runtime errors and surface when the tool is run.
  """
  @spec validate_tool([String.t()], String.t()) :: :ok | {:error, String.t()}
  def validate_tool(params, code) when is_list(params) and is_binary(code) do
    script = wrap(params, code) <> "\nreturn true"

    case run(fn -> Lua.eval!(build(nil), script) end) do
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
    run(fn -> Lua.eval!(lua, script) end)
  end

  defp build(nil), do: HostApi.install(Lua.new())
  defp build(ctx), do: HostApi.install(Lua.new()) |> StoreApi.install(ctx)

  defp wrap(params, code) do
    "local function __tool(#{Enum.join(params, ", ")})\n#{code}\nend\n"
  end

  defp run(fun) do
    {results, _lua} = fun.()
    {:ok, format(results)}
  rescue
    # Lua compile/runtime errors are useful to the model, so surface them. Any
    # other exception (e.g. a host FunctionClauseError) would leak Elixir module
    # paths/internals, so report it generically.
    e in [Lua.CompilerException, Lua.RuntimeException] -> {:error, Exception.message(e)}
    _other -> {:error, "Lua evaluation failed"}
  end

  defp format([]), do: "nil"
  defp format([value]), do: format_value(value)
  defp format(values), do: "[" <> Enum.map_join(values, ", ", &format_value/1) <> "]"

  defp format_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      # Never inspect/1 the value: Luerl function refs, closures, and raw binaries
      # leak Erlang/Elixir internals to the model. Return a neutral placeholder.
      {:error, _} -> "<unencodable lua value>"
    end
  end
end
