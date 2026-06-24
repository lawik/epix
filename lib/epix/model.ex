defmodule Epix.Model do
  @moduledoc """
  Model wiring for Berget AI, which exposes an OpenAI-compatible Chat Completions
  API. req_llm's default provider is OpenAI-compatible, so we use `:openai` with a
  custom `base_url`.
  """

  @base_url "https://api.berget.ai/v1"
  @default_id "zai-org/GLM-5.2"

  @spec berget(String.t()) :: ReqLLM.Model.t()
  def berget(id \\ @default_id) do
    ReqLLM.model!(%{provider: :openai, id: id, base_url: @base_url})
  end

  @doc "The Berget API key from the BERGET_API_KEY env var."
  @spec api_key() :: String.t() | nil
  def api_key(), do: System.get_env("BERGET_API_KEY")
end
