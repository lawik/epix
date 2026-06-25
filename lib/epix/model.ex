defmodule Epix.Model do
  @moduledoc """
  Model wiring — neutral over providers.

  Epix ships with no built-in vendor. The model used when a caller does not pass
  its own is resolved from the environment, so the same code runs against any
  provider req_llm supports:

    * `EPIX_MODEL`    — a req_llm model spec, e.g. `"openai:gpt-4o"` or
                        `"anthropic:claude-sonnet-4-6"`
    * `EPIX_BASE_URL` — optional endpoint override for OpenAI-compatible
                        gateways (kept off the spec so any provider/id resolves)
    * `EPIX_API_KEY`  — the API key (`api_key/0`)

  These helpers (`default/0`, `api_key/0`, `from_env/0`) read the environment so
  callers don't scatter `System.get_env` around — but they are a boundary
  convenience for dev tools and tests. The library core (`Epix.Session`) never
  reads the environment; it takes `:model`/`:api_key` explicitly. With nothing
  configured, `default/0` raises rather than assuming a vendor.
  """

  @doc """
  The default model, resolved from `EPIX_MODEL` (and optional `EPIX_BASE_URL`).

  Raises with a directive message when `EPIX_MODEL` is unset and no `:model`
  option was given, rather than assuming a provider.
  """
  @spec default() :: struct()
  def default do
    spec =
      System.get_env("EPIX_MODEL") ||
        raise """
        No model configured. Set EPIX_MODEL to a req_llm model spec \
        (e.g. "openai:gpt-4o" or "anthropic:claude-sonnet-4-6"), optionally with \
        EPIX_BASE_URL for an OpenAI-compatible gateway, or pass `:model` to \
        Epix.Session.
        """

    model(spec, System.get_env("EPIX_BASE_URL"))
  end

  @doc """
  Builds a req_llm model from a spec string, optionally overriding the provider
  endpoint with `base_url` for OpenAI-compatible gateways.
  """
  @spec model(String.t(), String.t() | nil) :: struct()
  def model(spec, base_url \\ nil)

  def model(spec, nil) when is_binary(spec), do: ReqLLM.model!(spec)

  # With a custom endpoint we use the inline-attrs form so an off-catalog model id
  # resolves cleanly — the string-spec path emits an "unverified model" warning
  # for ids req_llm does not know. The provider segment is operator-supplied
  # config, so turning it into an atom is bounded and safe.
  def model(spec, base_url) when is_binary(spec) and is_binary(base_url) do
    case String.split(spec, ":", parts: 2) do
      [provider, id] ->
        ReqLLM.model!(%{provider: String.to_atom(provider), id: id, base_url: base_url})

      [id] ->
        ReqLLM.model!(%{provider: :openai, id: id, base_url: base_url})
    end
  end

  @doc "The API key from the `EPIX_API_KEY` environment variable."
  @spec api_key() :: String.t() | nil
  def api_key, do: System.get_env("EPIX_API_KEY")

  @doc """
  A `[model:, api_key:]` keyword built from the `EPIX_*` environment, ready to
  splat into `Epix.Session.start_link/1`.

  The boundary convenience for dev tools and tests: the session never reads the
  environment, so something has to turn `EPIX_*` into explicit options — this
  does. Raises (via `default/0`) when `EPIX_MODEL` is unset.

      Epix.start_session([verbose: true] ++ Epix.Model.from_env())
  """
  @spec from_env() :: keyword()
  def from_env, do: [model: default(), api_key: api_key()]
end
