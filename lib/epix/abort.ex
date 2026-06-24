defmodule Epix.Abort do
  @moduledoc """
  A cheap, lock-free cancellation token.

  Backed by `:atomics`, so it can be read on a hot path (between stream chunks,
  between tool calls) and set from another process. Threaded through the run
  context to model and tool effects so a run can observe cancellation.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref()}

  @doc "Creates a fresh, un-cancelled token."
  @spec new() :: t()
  def new(), do: %__MODULE__{ref: :atomics.new(1, signed: false)}

  @doc "Marks the token cancelled. Idempotent."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}), do: :atomics.put(ref, 1, 1)

  @doc "Whether the token has been cancelled. `nil` is treated as never-cancelled."
  @spec cancelled?(t() | nil) :: boolean()
  def cancelled?(nil), do: false
  def cancelled?(%__MODULE__{ref: ref}), do: :atomics.get(ref, 1) == 1
end
