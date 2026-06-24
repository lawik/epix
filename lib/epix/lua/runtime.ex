defmodule Epix.Lua.Runtime do
  @moduledoc """
  Stateless Lua execution primitives.

  Every call builds a fresh sandboxed Lua VM with the host API installed, so runs
  are isolated from each other. Durable state (the registry of defined tools)
  lives in `Epix.Lua.Sandbox`; this module only knows how to compile and run.

  Results and errors are returned as strings ready to hand back to the model.
  """

  alias Epix.Lua.HostApi

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @doc "Evaluates a one-shot Lua snippet. Use `return X` to produce a result."
  @spec eval(String.t()) :: result()
  def eval(code) when is_binary(code) do
    run(fn -> Lua.eval!(build(), code) end)
  end

  @doc """
  Validates that a tool body compiles, given its parameter names.

  Only checks syntax (compile time). References to undefined host functions are
  runtime errors and surface when the tool is run.
  """
  @spec validate_tool([String.t()], String.t()) :: :ok | {:error, String.t()}
  def validate_tool(params, code) when is_list(params) and is_binary(code) do
    script = wrap(params, code) <> "\nreturn true"

    case run(fn -> Lua.eval!(build(), script) end) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc "Runs a stored tool body with the given argument map (string keys)."
  @spec run_tool([String.t()], String.t(), map()) :: result()
  def run_tool(params, code, args) when is_list(params) and is_binary(code) and is_map(args) do
    lua =
      Enum.reduce(params, build(), fn p, acc ->
        Lua.set!(acc, ["__args", p], Map.get(args, p))
      end)

    call = Enum.map_join(params, ", ", fn p -> "__args.#{p}" end)
    script = wrap(params, code) <> "return __tool(#{call})"
    run(fn -> Lua.eval!(lua, script) end)
  end

  defp build(), do: HostApi.install(Lua.new())

  defp wrap(params, code) do
    "local function __tool(#{Enum.join(params, ", ")})\n#{code}\nend\n"
  end

  defp run(fun) do
    {results, _lua} = fun.()
    {:ok, format(results)}
  rescue
    e in [Lua.CompilerException, Lua.RuntimeException] -> {:error, Exception.message(e)}
    e -> {:error, Exception.message(e)}
  end

  defp format([]), do: "nil"
  defp format([value]), do: format_value(value)
  defp format(values), do: "[" <> Enum.map_join(values, ", ", &format_value/1) <> "]"

  defp format_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
