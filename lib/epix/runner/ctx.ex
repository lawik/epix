defmodule Epix.Runner.Ctx do
  @moduledoc """
  The effect context handed to `model_fun`/`tool_fun`.

  Deliberately just two fields — the observability sink and the cancellation
  token — so the effect contract is small and discoverable. The driver's hooks
  live in `Epix.Runner.Hooks`, not here, and are never passed to the effects.
  """

  alias Epix.{Abort, Event}

  @enforce_keys [:emit, :abort]
  defstruct [:emit, :abort]

  @type t :: %__MODULE__{emit: Event.emit(), abort: Abort.t()}
end
