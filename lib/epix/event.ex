defmodule Epix.Event do
  @moduledoc """
  Progress events emitted by the loop driver, the Elixir analogue of Pi's `emit`
  sink.

  The pure core stays pure: events are emitted by `Epix.Runner` (the imperative
  shell) at each effect boundary, never by `Epix.Loop`. An emit function is a
  plain `(event -> any)` injected into `Epix.Runner.run/4`; the default is a
  no-op. This is the seam any frontend (a Solve controller, an LSP/MCP server, a
  log) consumes to observe a run without touching the loop.
  """

  @type t ::
          {:status, :thinking | :running_tools | :idle}
          | {:request, %{step: non_neg_integer()}}
          | {:response, %{finish_reason: atom() | nil, ms: non_neg_integer(), tokens: non_neg_integer()}}
          | {:assistant, %{text: String.t() | nil, tool_calls: [%{name: String.t(), args: String.t()}]}}
          | {:tool_start, %{name: String.t()}}
          | {:tool_result, %{name: String.t(), body: String.t()}}
          | {:error, term()}

  @type emit :: (t() -> any())

  @doc "A no-op emit function."
  @spec noop() :: emit()
  def noop(), do: fn _event -> :ok end
end
