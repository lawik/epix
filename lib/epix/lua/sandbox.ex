defmodule Epix.Lua.Sandbox do
  @moduledoc """
  Session-scoped owner of Lua state: the registry of model-defined tools.

  A `GenServer` so the registry survives across many turns of an agent run. The
  actual compilation/execution is delegated to `Epix.Lua.Runtime`, which builds a
  fresh isolated VM per call. This GenServer only holds durable data, which keeps
  it easy to later snapshot to disk or front with a `Solve` controller for the UI.
  """

  use GenServer

  alias Epix.Lua.Runtime

  @type tool :: %{description: String.t(), params: [String.t()], code: String.t()}

  # --- client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Evaluates a one-shot Lua snippet."
  @spec eval(GenServer.server(), String.t()) :: Runtime.result()
  def eval(server, code), do: GenServer.call(server, {:eval, code})

  @doc "Defines (or replaces) a reusable Lua tool. Validates that it compiles."
  @spec define_tool(GenServer.server(), String.t(), String.t(), [String.t()], String.t()) ::
          :ok | {:error, String.t()}
  def define_tool(server, name, description, params, code) do
    GenServer.call(server, {:define_tool, name, description, params, code})
  end

  @doc "Runs a previously defined tool with an argument map (string keys)."
  @spec run_tool(GenServer.server(), String.t(), map()) :: Runtime.result()
  def run_tool(server, name, args), do: GenServer.call(server, {:run_tool, name, args})

  @doc "Lists defined tools as `%{name, description, params}` maps."
  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(server), do: GenServer.call(server, :list_tools)

  @doc "Replaces the set of namespaces the agent's Lua may access."
  @spec set_namespaces(GenServer.server(), [String.t()]) :: :ok
  def set_namespaces(server, namespaces),
    do: GenServer.call(server, {:set_namespaces, namespaces})

  @doc "Returns the namespaces currently accessible to the agent's Lua."
  @spec namespaces(GenServer.server()) :: [String.t()]
  def namespaces(server), do: GenServer.call(server, :namespaces)

  # --- server ---

  @impl true
  def init(opts) do
    {:ok, %{tools: %{}, store: opts[:store], namespaces: opts[:namespaces] || []}}
  end

  @impl true
  def handle_call({:eval, code}, _from, state) do
    {:reply, Runtime.eval(code, lua_ctx(state)), state}
  end

  def handle_call({:define_tool, name, description, params, code}, _from, state) do
    params = normalize_params(params)

    with :ok <- validate_param_names(params),
         :ok <- Runtime.validate_tool(params, code) do
      tool = %{description: description, params: params, code: code}
      {:reply, :ok, put_in(state, [:tools, name], tool)}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:run_tool, name, args}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, %{params: params, code: code}} ->
        {:reply, Runtime.run_tool(params, code, normalize_args(args), lua_ctx(state)), state}

      :error ->
        {:reply,
         {:error, "no tool named #{inspect(name)}. Define it first or call lua_list_tools."},
         state}
    end
  end

  def handle_call(:list_tools, _from, state) do
    tools =
      Enum.map(state.tools, fn {name, t} ->
        %{name: name, description: t.description, params: t.params}
      end)

    {:reply, tools, state}
  end

  def handle_call({:set_namespaces, namespaces}, _from, state) do
    {:reply, :ok, %{state | namespaces: namespaces}}
  end

  def handle_call(:namespaces, _from, state), do: {:reply, state.namespaces, state}

  # The `store` API is installed only when a store is configured; the granted
  # namespaces are snapshotted into each eval.
  defp lua_ctx(%{store: nil}), do: nil

  defp lua_ctx(%{store: store, namespaces: namespaces}),
    do: %{store: store, namespaces: namespaces}

  defp normalize_params(nil), do: []
  defp normalize_params(params) when is_list(params), do: Enum.map(params, &to_string/1)

  # Params become Lua locals; a non-identifier would compile-fail at run time even
  # though it passed validation. Reject it up front so a defined tool is runnable.
  @param_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  defp validate_param_names(params) do
    case Enum.find(params, &(not Regex.match?(@param_pattern, &1))) do
      nil -> :ok
      bad -> {:error, "invalid parameter name: #{inspect(bad)}"}
    end
  end

  defp normalize_args(nil), do: %{}
  defp normalize_args(args) when is_map(args), do: args
end
