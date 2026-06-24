defmodule Epix.Lua.HostApi do
  @moduledoc """
  The host API surface exposed *inside* the Lua sandbox.

  This is the single source of truth: each entry both installs an Elixir-backed
  function into the Lua `host` table and renders into the documentation that goes
  into the model's base context. Keep the functions trivial for now; they exist
  to exercise the Elixir <-> Lua bridge and error surfacing, not to be useful.

  Functions registered via `Lua.set!/3` receive their args as a list of already
  encoded Lua values and must return a list of encoded values. Scalars (numbers,
  binaries, booleans) are encoded as-is, so simple functions need no encode step.
  """

  @type spec :: %{
          name: String.t(),
          signature: String.t(),
          doc: String.t(),
          fun: ([term()] -> [term()])
        }

  @specs [
    %{
      name: "echo",
      signature: "host.echo(...)",
      doc: "Returns its arguments unchanged. Useful to confirm values round-trip.",
      fun: &__MODULE__.echo/1
    },
    %{
      name: "add",
      signature: "host.add(a, b)",
      doc: "Returns the sum of two numbers.",
      fun: &__MODULE__.add/1
    },
    %{
      name: "upper",
      signature: "host.upper(s)",
      doc: "Returns the uppercased string.",
      fun: &__MODULE__.upper/1
    },
    %{
      name: "reverse",
      signature: "host.reverse(s)",
      doc: "Returns the string reversed.",
      fun: &__MODULE__.reverse/1
    },
    %{
      name: "now",
      signature: "host.now()",
      doc: "Returns the current Unix time in seconds (integer).",
      fun: &__MODULE__.now/1
    }
  ]

  @doc "Installs the host API into a Lua state, returning the updated state."
  @spec install(Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    Enum.reduce(@specs, lua, fn %{name: name, fun: fun}, acc ->
      Lua.set!(acc, ["host", name], fun)
    end)
  end

  @doc "Returns the raw specs (name/signature/doc)."
  @spec specs() :: [spec()]
  def specs(), do: @specs

  @doc "Renders the host API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    @specs
    |> Enum.map_join("\n", fn %{signature: sig, doc: doc} -> "- `#{sig}` — #{doc}" end)
  end

  # --- implementations (must return a list of encoded values) ---

  @spec echo([term()]) :: [term()]
  def echo(args), do: args

  @spec add([term()]) :: [number()]
  def add([a, b]) when is_number(a) and is_number(b), do: [a + b]
  def add(_args), do: raise(Lua.RuntimeException, "host.add expects two numbers")

  @spec upper([term()]) :: [String.t()]
  def upper([s]) when is_binary(s), do: [String.upcase(s)]
  def upper(_args), do: raise(Lua.RuntimeException, "host.upper expects a string")

  @spec reverse([term()]) :: [String.t()]
  def reverse([s]) when is_binary(s), do: [String.reverse(s)]
  def reverse(_args), do: raise(Lua.RuntimeException, "host.reverse expects a string")

  @spec now([term()]) :: [integer()]
  def now(_args), do: [System.os_time(:second)]
end
