defmodule Epix.Lua.StoreApi do
  @moduledoc """
  Installs the `store` table into a Lua state: the agent's storage interop.

  Every call takes an explicit `namespace` (an arbitrary host-defined string). The
  functions close over the granted namespace set, so a call to a namespace the
  agent does not currently have access to raises a Lua error. Values round-trip
  between Lua and Elixir — scalars as-is, tables as nested maps/lists — so stored
  data is clean Elixir terms the host can also read.
  """

  alias Epix.Store

  @type ctx :: %{store: Store.t(), namespaces: [String.t()]}

  @doc "Installs `store.*` into the Lua state, bound to the store and granted namespaces."
  @spec install(Lua.t(), ctx()) :: Lua.t()
  def install(%Lua{} = lua, %{store: store, namespaces: namespaces}) do
    lua
    |> Lua.set!(["store", "get"], get_fun(store, namespaces))
    |> Lua.set!(["store", "put"], put_fun(store, namespaces))
    |> Lua.set!(["store", "delete"], delete_fun(store, namespaces))
    |> Lua.set!(["store", "keys"], keys_fun(store, namespaces))
    |> Lua.set!(["store", "namespaces"], namespaces_fun(namespaces))
  end

  @doc "Renders the store API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    """
    - `store.get(namespace, key)` — read a value, or nil if absent.
    - `store.put(namespace, key, value)` — store a value (string/number/boolean/table). Returns true.
    - `store.delete(namespace, key)` — remove a key. Returns true.
    - `store.keys(namespace)` — list the keys in a namespace.
    - `store.namespaces()` — list the namespaces you can currently access.

    Every call requires a `namespace`; accessing a namespace you do not have
    returns an error. Use `list_namespaces` (or `store.namespaces()`) to discover them.
    """
  end

  defp get_fun(store, namespaces) do
    fn
      [namespace, key], lua ->
        check_access!(namespace, namespaces)
        encoded_value(lua, Store.get(store, namespace, to_key(key)))

      _args, _lua ->
        raise Lua.RuntimeException, "store.get expects (namespace, key)"
    end
  end

  defp put_fun(store, namespaces) do
    fn
      [namespace, key, value], lua ->
        check_access!(namespace, namespaces)

        case storable(Lua.decode!(lua, value)) do
          {:ok, term} ->
            Store.put(store, namespace, to_key(key), term)
            {[true], lua}

          :error ->
            raise Lua.RuntimeException,
                  "store.put value must be a string, number, boolean, or table"
        end

      _args, _lua ->
        raise Lua.RuntimeException, "store.put expects (namespace, key, value)"
    end
  end

  defp delete_fun(store, namespaces) do
    fn
      [namespace, key], lua ->
        check_access!(namespace, namespaces)
        Store.delete(store, namespace, to_key(key))
        {[true], lua}

      _args, _lua ->
        raise Lua.RuntimeException, "store.delete expects (namespace, key)"
    end
  end

  defp keys_fun(store, namespaces) do
    fn
      [namespace], lua ->
        check_access!(namespace, namespaces)
        {encoded, lua} = Lua.encode!(lua, Store.keys(store, namespace))
        {[encoded], lua}

      _args, _lua ->
        raise Lua.RuntimeException, "store.keys expects (namespace)"
    end
  end

  defp namespaces_fun(namespaces) do
    fn _args, lua ->
      {encoded, lua} = Lua.encode!(lua, namespaces)
      {[encoded], lua}
    end
  end

  # Raises a Lua error unless the namespace is a granted string.
  defp check_access!(namespace, namespaces) when is_binary(namespace) do
    unless namespace in namespaces do
      raise Lua.RuntimeException, "namespace #{inspect(namespace)} is not accessible"
    end

    :ok
  end

  defp check_access!(_namespace, _namespaces),
    do: raise(Lua.RuntimeException, "namespace must be a string")

  defp encoded_value(lua, nil), do: {[nil], lua}

  defp encoded_value(lua, value) do
    {encoded, lua} = Lua.encode!(lua, value)
    {[encoded], lua}
  end

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key), do: to_string(key)

  # Decoded Lua -> a clean, storable Elixir term. A Lua table decodes to a list of
  # {key, value} pairs; turn an integer-sequence into a list, anything else into a
  # map, and reject values that are not pure data.
  defp storable(value) do
    normalized = normalize(value)
    if storable?(normalized), do: {:ok, normalized}, else: :error
  end

  defp normalize([]), do: %{}

  defp normalize(pairs) when is_list(pairs) do
    cond do
      not Enum.all?(pairs, &match?({_, _}, &1)) -> pairs
      sequence?(pairs) -> Enum.map(pairs, fn {_index, value} -> normalize(value) end)
      true -> Map.new(pairs, fn {key, value} -> {key, normalize(value)} end)
    end
  end

  defp normalize(scalar), do: scalar

  defp sequence?(pairs), do: Enum.map(pairs, &elem(&1, 0)) == Enum.to_list(1..length(pairs))

  defp storable?(value)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value),
       do: true

  defp storable?(value) when is_map(value),
    do: Enum.all?(value, fn {key, val} -> storable?(key) and storable?(val) end)

  defp storable?(value) when is_list(value), do: Enum.all?(value, &storable?/1)
  defp storable?(_value), do: false
end
