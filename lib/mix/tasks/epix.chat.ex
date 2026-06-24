defmodule Mix.Tasks.Epix.Chat do
  @shortdoc "Start a basic Epix chat TUI (Solve + term_ui + the loop)"
  @moduledoc """
  Starts a minimal chat interface wiring the three building blocks together:

    * `Epix.Chat.App` (Solve) owns the chat state and runs the loop,
    * `Epix.Chat.UI` (term_ui) renders it and captures input,
    * `Epix.Chat.Bridge` forwards Solve updates into the term_ui runtime.

  Needs a real terminal and `BERGET_API_KEY` in the environment.

      $ source .envrc && mix epix.chat
  """

  use Mix.Task

  alias Epix.Chat.{App, Bridge, Ticker, UI}
  alias TermUI.Runtime

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    {:ok, app} = App.start_link()
    Application.put_env(:epix, :chat, %{app: app, controller: :chat})

    {cols, rows} = terminal_size()
    {:ok, runtime} = Runtime.start_link(root: UI)
    # The runtime only broadcasts size on SIGWINCH, so seed the real size now.
    Runtime.send_message(runtime, :root, {:resize, cols, rows})
    {:ok, _bridge} = Bridge.start_link(app: app, controller: :chat, runtime: runtime)
    {:ok, _ticker} = Ticker.start_link(runtime: runtime)

    ref = Process.monitor(runtime)

    receive do
      {:DOWN, ^ref, :process, ^runtime, _reason} -> :ok
    end
  end

  defp terminal_size() do
    with {:ok, rows} <- :io.rows(), {:ok, cols} <- :io.columns() do
      {cols, rows}
    else
      _ -> {80, 24}
    end
  end
end
