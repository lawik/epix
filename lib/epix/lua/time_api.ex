defmodule Epix.Lua.TimeApi do
  @moduledoc """
  Installs the `time` table into the Lua sandbox.

  The standard `os` library is removed by the sandbox, so this exposes the one
  host-clock capability the agent legitimately needs. Real capabilities (storage,
  search, …) live under their own tables, not a catch-all.
  """

  @doc "Installs `time.*` into a Lua state, returning the updated state."
  @spec install(Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    Lua.set!(lua, ["time", "now"], &__MODULE__.now/1)
  end

  @doc "Renders the time API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    "- `time.now()` — current Unix time in seconds (integer)."
  end

  @spec now([term()]) :: [integer()]
  def now(_args), do: [System.os_time(:second)]
end
