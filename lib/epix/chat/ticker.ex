defmodule Epix.Chat.Ticker do
  @moduledoc """
  Sends a periodic `:tick` to the term_ui root so the UI can show elapsed time and
  animate a spinner during a long, non-streaming model call. Without this the view
  is frozen on `[thinking]` while the request is in flight.
  """

  use GenServer

  @default_interval 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{runtime: runtime, interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    TermUI.Runtime.send_message(state.runtime, :root, :tick)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
