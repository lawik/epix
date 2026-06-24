defmodule Epix.Loop.Config do
  @moduledoc """
  Immutable configuration for an agent loop run.

  Plain data only. The pure loop core (`Epix.Loop`) reads `:max_steps`; the rest
  (`:model`, `:api_key`, `:tools`, `:temperature`, `:max_tokens`) is consumed by
  the effectful boundary (the model function the driver is given), never by the
  pure core. Kept faithful to Pi, where the loop config carries model/reasoning
  and the side-effecting bits are injected callbacks.
  """

  defstruct model: nil,
            api_key: nil,
            tools: [],
            temperature: 0.2,
            max_tokens: 1024,
            max_steps: 8,
            receive_timeout: 60_000

  @type t :: %__MODULE__{
          model: struct() | nil,
          api_key: String.t() | nil,
          tools: [ReqLLM.Tool.t()],
          temperature: number(),
          max_tokens: pos_integer(),
          max_steps: pos_integer(),
          receive_timeout: pos_integer()
        }
end
