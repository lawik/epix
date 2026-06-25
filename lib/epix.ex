defmodule Epix do
  @moduledoc """
  Epix: a coding-agent harness where the model operates by writing sandboxed Lua.

  Building blocks (frontend-agnostic, no CLI/UI yet):

    * `Epix.Loop` - the pure agent loop (struct + transitions), faithful to Pi
    * `Epix.Runner` - drives the loop, performing injected effects
    * `Epix.Session` - GenServer shell owning the sandbox and conversation
    * `Epix.Lua.Sandbox` / `Epix.Lua.Runtime` and the API tables
      (`Epix.Lua.TimeApi` / `Epix.Lua.KvApi` / `Epix.Lua.WebApi`) - the Lua layer
    * `Epix.Tools` - the model-facing tools (eval/define/run/list)
    * `Epix.SystemPrompt` - the base context

      # Pass the model/key explicitly; `from_env/0` sources them from EPIX_* env.
      {:ok, session} = Epix.start_session(Epix.Model.from_env())
      Epix.Session.run(session, "Use Lua to compute 19 + 23.")
  """

  alias Epix.Session

  @doc "Starts a session. See `Epix.Session.start_link/1` for options."
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []), do: Session.start_link(opts)

  @doc """
  Convenience one-shot: start a session, run one prompt, return the result, and
  stop the session (and its linked sandbox) so nothing leaks. Use
  `start_session/1` + `Epix.Session.run/3` to keep a session across turns.
  """
  @spec run(String.t(), keyword()) :: Epix.Loop.result() | {:error, term()}
  def run(prompt, opts \\ []) do
    case Session.start_link(opts) do
      {:ok, session} ->
        try do
          Session.run(session, prompt)
        after
          GenServer.stop(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
