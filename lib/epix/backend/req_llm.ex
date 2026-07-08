defmodule Epix.Backend.ReqLLM do
  @moduledoc """
  The default `Epix.Backend`: streams a turn from any provider `req_llm` supports.

  `config.model` is a `ReqLLM` model. The provider request is streamed through
  `Epix.ModelStream`, which taps deltas to `emit`, honors the `abort` token, and
  normalizes the completed response into an `Epix.Loop.Turn`.
  """

  @behaviour Epix.Backend

  alias Epix.Loop.Config
  alias Epix.ModelStream

  @impl Epix.Backend
  def call(context, %Config{} = config, ctx) do
    ModelStream.run(fn -> request(config, context) end, ctx)
  end

  defp request(%Config{} = config, context) do
    ReqLLM.stream_text(config.model, context,
      tools: config.tools,
      api_key: config.api_key,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      receive_timeout: config.receive_timeout
    )
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
