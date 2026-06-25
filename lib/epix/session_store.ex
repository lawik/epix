defmodule Epix.SessionStore do
  @moduledoc """
  Per-session durable storage — deliberately separate from `Epix.Store` (the
  namespaced KV) so the two can never be confused.

  A session is the history of one exchange with an agent (its conversation and the
  capabilities it was granted, like namespaces). It is persisted to **its own
  CubDB**, in a directory named by the session id under a base directory:

      <base_dir>/<session_id>/

  So each session is one storage backend, a KV namespace is a different one, and
  the set of sessions is just the set of id-named directories under `base_dir` —
  no separate index needed.

  A KV (`Epix.Store`) is namespaced and a session may be granted many namespaces;
  those are independent backends. This module never touches them.
  """

  @record_key :record

  @type record :: %{
          messages: [ReqLLM.Message.t()],
          namespaces: [String.t()],
          updated_at: integer()
        }

  @doc "Opens (creating if absent) the CubDB for session `id`, linked to the caller."
  @spec open(Path.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def open(base_dir, id), do: CubDB.start_link(data_dir: Path.join(base_dir, id))

  @doc "Loads the session record from an open session db, or `nil` if none yet."
  @spec load(pid()) :: record() | nil
  def load(db), do: CubDB.get(db, @record_key)

  @doc "Writes the session record to an open session db."
  @spec save(pid(), record()) :: :ok
  def save(db, record), do: CubDB.put(db, @record_key, record)

  @doc "Lists the session ids that have storage under `base_dir` (the index)."
  @spec list(Path.t()) :: [String.t()]
  def list(base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(base_dir, &1)))
      {:error, _reason} -> []
    end
  end

  @doc "Deletes a session's storage directory (the db must be closed first)."
  @spec delete(Path.t(), String.t()) :: :ok
  def delete(base_dir, id) do
    File.rm_rf!(Path.join(base_dir, id))
    :ok
  end
end
