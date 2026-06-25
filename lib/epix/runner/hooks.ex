defmodule Epix.Runner.Hooks do
  @moduledoc """
  The driver's injected hooks, with all defaults in one place.

  Each hook is an extension point the `Epix.Runner` consumes itself (the effects
  never see them): `steering`/`follow_up` supply user messages before a model call
  and when a run would otherwise halt; `compaction` rewrites the context on
  overflow; `transform_context` rewrites the messages sent to the model
  non-destructively; `before_tool_call`/`after_tool_call` gate and post-process
  each tool; `prepare_next_turn` can swap model/context between turns.
  """

  @type messages :: [ReqLLM.Message.t()]
  @type t :: %__MODULE__{
          steering: (-> [String.t() | list()]),
          follow_up: (-> [String.t() | list()]),
          compaction: (messages() -> {:ok, messages()} | {:error, term()}),
          transform_context: (messages() -> messages()),
          before_tool_call: (ReqLLM.ToolCall.t() -> :ok | {:block, String.t()}),
          after_tool_call: (ReqLLM.ToolCall.t(), String.t() -> String.t()),
          prepare_next_turn: (Epix.Loop.State.t() -> Epix.Loop.State.t())
        }

  defstruct steering: &__MODULE__.no_messages/0,
            follow_up: &__MODULE__.no_messages/0,
            compaction: &__MODULE__.identity_compaction/1,
            transform_context: &Function.identity/1,
            before_tool_call: &__MODULE__.allow/1,
            after_tool_call: &__MODULE__.keep/2,
            prepare_next_turn: &Function.identity/1

  @keys ~w(steering follow_up compaction transform_context before_tool_call after_tool_call prepare_next_turn)a

  @doc "Builds hooks from run options, falling back to the struct defaults."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    struct(__MODULE__, Keyword.take(opts, @keys))
  end

  @doc false
  @spec no_messages() :: []
  def no_messages(), do: []

  @doc false
  @spec identity_compaction(messages()) :: {:ok, messages()}
  def identity_compaction(messages), do: {:ok, messages}

  @doc false
  @spec allow(ReqLLM.ToolCall.t()) :: :ok
  def allow(_call), do: :ok

  @doc false
  @spec keep(ReqLLM.ToolCall.t(), String.t()) :: String.t()
  def keep(_call, body), do: body
end
