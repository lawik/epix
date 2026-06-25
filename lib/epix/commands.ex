defmodule Epix.Commands do
  @moduledoc """
  The operator command layer: frontend-agnostic actions that control a session and
  the loop, as opposed to `Epix.Tools` (which the *model* calls). Any frontend —
  TUI, GUI, HTTP, or MCP — discovers them via `specs/0` and runs them via
  `dispatch/3`, so the same verbs work everywhere.

  Commands kept here are deliberately UI-agnostic: nothing tied to a terminal, a
  window, or a pointer. Session-lifecycle verbs that need durable storage
  (resume/fork/tree) and model switching are intentionally not here yet.
  """

  alias Epix.{Command, Session}

  @doc "The available commands, for a frontend to render or an MCP server to expose."
  @spec specs() :: [Command.t()]
  def specs() do
    [
      %Command{name: "cancel", summary: "Abort the in-flight run, if any.", args: []},
      %Command{
        name: "steer",
        summary: "Inject a user message into the in-flight run before its next model call.",
        args: [%{name: "message", type: :string, required: true, summary: "Text to inject."}]
      },
      %Command{
        name: "reset",
        summary: "Clear the conversation and start fresh (keeps the sandbox and storage).",
        args: []
      },
      %Command{
        name: "status",
        summary:
          "Report session state: whether a run is active, the model, namespaces, message count.",
        args: []
      },
      %Command{
        name: "history",
        summary: "Return the conversation so far as a list of role/text messages.",
        args: []
      },
      %Command{
        name: "set_namespaces",
        summary: "Replace the storage namespaces the agent may access.",
        args: [
          %{
            name: "namespaces",
            type: :string_list,
            required: true,
            summary: "Namespaces to grant."
          }
        ]
      }
    ]
  end

  @doc """
  Runs a command (by name) against a session. `args` is a string-keyed map (as a
  frontend or MCP client would supply). Returns `{:ok, result_map}` or
  `{:error, message}`.
  """
  @spec dispatch(Session.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def dispatch(session, name, args \\ %{})

  def dispatch(session, "cancel", _args) do
    case Session.cancel(session) do
      :ok -> {:ok, %{cancelled: true}}
      {:error, :idle} -> {:error, "no run is in progress"}
    end
  end

  def dispatch(session, "steer", %{"message" => message}) when is_binary(message) do
    case Session.steer(session, message) do
      :ok -> {:ok, %{steered: true}}
      {:error, :idle} -> {:error, "no run is in progress"}
    end
  end

  def dispatch(_session, "steer", _args), do: {:error, "steer requires a 'message' string"}

  def dispatch(session, "reset", _args) do
    case Session.reset(session) do
      :ok -> {:ok, %{reset: true}}
      {:error, :busy} -> {:error, "cannot reset while a run is in progress"}
    end
  end

  def dispatch(session, "status", _args), do: {:ok, Session.status(session)}

  def dispatch(session, "history", _args) do
    messages = session |> Session.context() |> Map.fetch!(:messages) |> Enum.map(&project/1)
    {:ok, %{messages: messages}}
  end

  def dispatch(session, "set_namespaces", %{"namespaces" => namespaces})
      when is_list(namespaces) do
    :ok = Session.set_namespaces(session, namespaces)
    {:ok, %{namespaces: namespaces}}
  end

  def dispatch(_session, "set_namespaces", _args),
    do: {:error, "set_namespaces requires a 'namespaces' list"}

  def dispatch(_session, name, _args), do: {:error, "unknown command: #{name}"}

  defp project(message), do: %{role: message.role, text: message_text(message)}

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> ""
    end)
  end

  defp message_text(_message), do: ""
end
