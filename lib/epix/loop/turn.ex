defmodule Epix.Loop.Turn do
  @moduledoc """
  A normalized assistant turn: the result of one model call.

  This is the boundary type between the provider (req_llm) and the pure loop,
  mirroring Pi's split between a provider `AssistantMessage` and the loop's own
  view of it. The driver's model function returns a `Turn`; the pure core never
  touches `ReqLLM.Response` directly. That keeps the core trivially testable with
  hand-built turns and no network.

    * `message` - the assistant `ReqLLM.Message` to append to the context
    * `tool_calls` - tool calls the model wants run (empty when it is answering)
    * `text` - assistant text, if any
    * `finish_reason` - provider stop reason (`:stop`, `:tool_calls`, ...)
  """

  defstruct [:message, tool_calls: [], text: nil, finish_reason: nil, usage: nil]

  @type t :: %__MODULE__{
          message: ReqLLM.Message.t(),
          tool_calls: [ReqLLM.ToolCall.t()],
          text: String.t() | nil,
          finish_reason: atom() | nil,
          usage: map() | nil
        }
end
