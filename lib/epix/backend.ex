defmodule Epix.Backend do
  @moduledoc """
  A pluggable model backend: performs one model call and returns a normalized turn.

  The loop core is provider-neutral — it only needs `model_fun`, an effect that
  runs one model call over the conversation `context` and returns an
  `Epix.Loop.Turn`. A backend packages that effect as a named module so a session
  can choose where inference happens via the `:backend` option to
  `Epix.Session.start_link/1`. The default is `Epix.Backend.ReqLLM` (any provider
  req_llm supports); an alternative can run a local/on-device model instead.

  The `config.model` field is **backend-interpreted**: `Epix.Backend.ReqLLM`
  expects it to be a `ReqLLM` model, while another backend may expect its own
  handle or spec. Everything else the effect needs (tools, sampling, timeouts)
  travels on the `Epix.Loop.Config`.

  Tests still bypass this entirely by passing an explicit `:model_fun`, which
  takes precedence over the configured backend.
  """

  alias Epix.Loop.{Config, Turn}
  alias Epix.Runner.Ctx

  @doc """
  Runs one model call for `context` under `config` and returns a normalized turn.

  Receives the effect `Ctx` (the `emit` sink and the `abort` token) so it can
  stream deltas and honor cancellation. Returns `{:ok, Turn.t()}` or
  `{:error, reason}`; `{:error, :cancelled}` signals a cancelled call.
  """
  @callback call(ReqLLM.Context.t(), Config.t(), Ctx.t()) :: {:ok, Turn.t()} | {:error, term()}
end
