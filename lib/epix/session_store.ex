defmodule Epix.SessionStore do
  @moduledoc """
  Durable storage for whole agent sessions, on top of `Epix.Store` (CubDB).

  A session record is its conversation plus the namespaces it was granted, keyed
  by session id. Restoring a session by id resumes the conversation; the agent's
  kv namespaces persist independently (one CubDB each), so the data it stored
  comes back with it. Records live in one reserved namespace, separate from any
  agent namespace.
  """

  alias Epix.Store

  @namespace "_epix_sessions"

  @type record :: %{
          id: String.t(),
          messages: [ReqLLM.Message.t()],
          namespaces: [String.t()],
          updated_at: integer()
        }

  @doc "Persists a session's conversation and granted namespaces under `id`."
  @spec save(Store.t(), String.t(), %{messages: list(), namespaces: [String.t()]}) :: :ok
  def save(store, id, %{messages: messages, namespaces: namespaces}) do
    record = %{
      id: id,
      messages: messages,
      namespaces: namespaces,
      updated_at: System.os_time(:second)
    }

    Store.put(store, @namespace, id, record)
  end

  @doc "Loads a session record by id, or `nil` if there is none."
  @spec load(Store.t(), String.t()) :: record() | nil
  def load(store, id), do: Store.get(store, @namespace, id)

  @doc "Lists saved sessions (id + summary), most recently updated first."
  @spec list(Store.t()) :: [%{id: String.t(), updated_at: integer(), messages: non_neg_integer()}]
  def list(store) do
    store
    |> Store.keys(@namespace)
    |> Enum.map(&summarize(Store.get(store, @namespace, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @doc "Deletes a saved session (the conversation record only; its kv data persists)."
  @spec delete(Store.t(), String.t()) :: :ok
  def delete(store, id), do: Store.delete(store, @namespace, id)

  defp summarize(nil), do: nil

  defp summarize(record) do
    %{id: record.id, updated_at: record.updated_at, messages: length(record.messages)}
  end
end
