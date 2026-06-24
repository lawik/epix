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

  # --- server ---

  @impl true
  def init(_opts), do: {:ok, %{tools: %{}}}

  @impl true
  def handle_call({:eval, code}, _from, state) do
    {:reply, Runtime.eval(code), state}
  end

  def handle_call({:define_tool, name, description, params, code}, _from, state) do
    params = normalize_params(params)

    case Runtime.validate_tool(params, code) do
      :ok ->
        tool = %{description: description, params: params, code: code}
        {:reply, :ok, put_in(state, [:tools, name], tool)}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:run_tool, name, args}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, %{params: params, code: code}} ->
        {:reply, Runtime.run_tool(params, code, normalize_args(args)), state}

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

  defp normalize_params(nil), do: []
  defp normalize_params(params) when is_list(params), do: Enum.map(params, &to_string/1)

  defp normalize_args(nil), do: %{}
  defp normalize_args(args) when is_map(args), do: args
end
