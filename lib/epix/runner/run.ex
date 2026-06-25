defmodule Epix.Runner.Run do
  @moduledoc false
  # The driver's internal bundle, threaded through every step so the function
  # signatures stay to `(state, run)`. Holds the effects, the effect context
  # passed to them (`ctx`), the hooks the driver consumes, and the verbose flag.

  alias Epix.Runner.{Ctx, Hooks}

  @enforce_keys [:model_fun, :tool_fun, :ctx, :hooks]
  defstruct [:model_fun, :tool_fun, :ctx, :hooks, verbose: false]

  @type t :: %__MODULE__{
          model_fun: fun(),
          tool_fun: fun(),
          ctx: Ctx.t(),
          hooks: Hooks.t(),
          verbose: boolean()
        }
end
