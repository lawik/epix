defmodule Epix.Loop.State do
  @moduledoc """
  The state of a single agent loop run.

  A plain struct threaded by `Epix.Loop` (pure transitions) and `Epix.Runner`
  (which performs effects). It is intentionally not a process: testing pure
  functions over this struct is far simpler than testing a GenServer, and the
  driver can be exercised with fake effects.

  `phase` is the small state machine:

    * `:model` - next step is to call the model
    * `:tools` - `pending_calls` need to be executed, then fed back
    * `:done` - terminal; `result`/`error` hold the outcome
  """

  alias Epix.Loop.Config

  @enforce_keys [:context, :config]
  defstruct [
    :context,
    :config,
    step: 0,
    phase: :model,
    pending_calls: [],
    result: nil,
    error: nil,
    stop_reason: nil,
    follow_ups: 0
  ]

  @type phase :: :model | :tools | :done

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t(),
          config: Config.t(),
          step: non_neg_integer(),
          phase: phase(),
          pending_calls: [ReqLLM.ToolCall.t()],
          result: String.t() | nil,
          error: term() | nil,
          stop_reason: atom() | nil,
          follow_ups: non_neg_integer()
        }
end
