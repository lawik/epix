defmodule Epix.Chat.Bridge do
  @moduledoc """
  Adapter from Solve to a term_ui runtime.

  Subscribes to a controller and forwards each exposed-state update into the
  term_ui Elm root as a `{:solve, exposed}` message. This is the only module that
  knows about both Solve and term_ui; the controller stays frontend-agnostic, so a
  different frontend (API, MCP) would be a different adapter over the same
  controller.
  """

  use GenServer

  alias Solve.{Message, Update}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    app = Keyword.fetch!(opts, :app)
    controller = Keyword.fetch!(opts, :controller)
    runtime = Keyword.fetch!(opts, :runtime)

    exposed = Solve.subscribe(app, controller, self())
    forward(runtime, exposed)
    {:ok, %{runtime: runtime}}
  end

  @impl true
  def handle_info(%Message{type: :update, payload: %Update{exposed_state: exposed}}, state) do
    forward(state.runtime, exposed)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp forward(runtime, exposed) when is_map(exposed) do
    TermUI.Runtime.send_message(runtime, :root, {:solve, exposed})
  end

  defp forward(_runtime, _exposed), do: :ok
end
