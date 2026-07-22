defmodule Epix.Chat.Controller do
  @moduledoc """
  Solve controller owning chat state and the loop run.

  This is the frontend-agnostic source of truth: it exposes `%{messages, status,
  log}` to any subscriber (an API, an MCP server, or a TUI). On `:submit` it runs
  the loop in a Task so the controller stays responsive, and folds the loop's
  emitted events into exposed state via the pure `Epix.Chat.Projection`.
  """

  use Solve.Controller, events: [:submit, :cancel]

  alias Epix.Chat.Projection
  alias Epix.Session

  @impl Solve.Controller
  def init(params, _dependencies) do
    {:ok, session} = Session.start_link(session_opts(params))
    Map.put(Projection.new(), :session, session)
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{messages: state.messages, status: state.status, log: state.log, tokens: state.tokens}
  end

  @doc "Handles a `:submit` event with `%{text: prompt}`."
  @spec submit(%{text: String.t()}, map()) :: map()
  def submit(%{text: text}, %{session: session} = state) do
    controller = self()

    Task.start(fn ->
      emit = fn event -> send(controller, {:epix_event, event}) end
      result = Session.run(session, text, emit: emit)
      send(controller, {:epix_done, result})
    end)

    Projection.user_prompt(state, text)
  end

  @doc "Handles a `:cancel` event by aborting the in-flight run, if any."
  @spec cancel(map(), map()) :: map()
  def cancel(_payload, %{session: session} = state) do
    Session.cancel(session)
    state
  end

  @spec handle_info(term(), map()) :: map()
  def handle_info({:epix_event, event}, state), do: Projection.apply_event(state, event)
  def handle_info({:epix_done, result}, state), do: Projection.finish(state, result)
  def handle_info(_message, state), do: state

  defp session_opts(params) when is_map(params), do: Map.get(params, :session_opts, [])
  defp session_opts(_params), do: []
end
