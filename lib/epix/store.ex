defmodule Epix.Store do
  @moduledoc """
  A namespaced key-value store backed by CubDB.

  Each namespace is an arbitrary string whose meaning the host system decides
  (e.g. `"user:5"`, `"project:the-big-effort"`, `"agent-local:32a85"`). A
  namespace maps to its **own** CubDB process — which owns that namespace's file
  handle — started lazily under a `DynamicSupervisor` and registered by name in a
  `Registry`. So there is no single process owning every namespace's files: each
  namespace is independently owned, isolated, and shareable. Any caller asking for
  `"user:5"` resolves to the one CubDB registered for it (starting it if needed).

  This is a shared service that performs no access control; which namespaces a
  given agent may touch is enforced one layer up by the granted set a `Session`
  holds.

  Start it under a supervision tree and refer to it by name:

      {Epix.Store, name: MyApp.Store, dir: "priv/store"}

  Then `Epix.Store.put(MyApp.Store, "user:5", "k", v)` and friends.
  """

  use Supervisor

  @type t :: atom()
  @type namespace :: String.t()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor(name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    dir = Keyword.fetch!(opts, :dir)

    children = [
      {Registry, keys: :unique, name: registry(name), meta: [dir: dir]},
      {DynamicSupervisor, name: dynamic_supervisor(name), strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Reads `key` from `namespace`, returning `default` if absent."
  @spec get(t(), namespace(), term(), term()) :: term()
  def get(store, namespace, key, default \\ nil),
    do: CubDB.get(db(store, namespace), key, default)

  @doc "Writes `value` under `key` in `namespace`."
  @spec put(t(), namespace(), term(), term()) :: :ok
  def put(store, namespace, key, value), do: CubDB.put(db(store, namespace), key, value)

  @doc "Deletes `key` from `namespace`."
  @spec delete(t(), namespace(), term()) :: :ok
  def delete(store, namespace, key), do: CubDB.delete(db(store, namespace), key)

  @doc "Returns the keys present in `namespace`, in key order."
  @spec keys(t(), namespace()) :: [term()]
  def keys(store, namespace) do
    db(store, namespace) |> CubDB.select() |> Enum.map(fn {key, _value} -> key end)
  end

  # Resolves the namespace's CubDB pid, starting it if absent (races pick a winner).
  defp db(store, namespace) do
    case Registry.lookup(registry(store), namespace) do
      [{pid, _value}] -> pid
      [] -> start_db(store, namespace)
    end
  end

  defp start_db(store, namespace) do
    {:ok, dir} = Registry.meta(registry(store), :dir)

    spec = %{
      id: {CubDB, namespace},
      start:
        {CubDB, :start_link,
         [
           [
             data_dir: data_dir(dir, namespace),
             name: {:via, Registry, {registry(store), namespace}},
             auto_compact: true
           ]
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(dynamic_supervisor(store), spec) do
      {:ok, pid} -> pid
      # Two callers raced to open the same namespace; use the winner.
      {:error, {:already_started, pid}} -> pid
    end
  end

  # Namespaces are arbitrary (colons, slashes, …); encode to one safe, reversible
  # directory name per namespace.
  defp data_dir(base, namespace),
    do: Path.join(base, Base.url_encode64(namespace, padding: false))

  defp supervisor(name), do: Module.concat(name, "Supervisor")
  defp registry(name), do: Module.concat(name, "Registry")
  defp dynamic_supervisor(name), do: Module.concat(name, "DynamicSupervisor")
end
