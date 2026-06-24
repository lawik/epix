defmodule Epix.Chat.App do
  @moduledoc """
  The Solve app hosting the chat controller graph. One controller for now.
  """

  use Solve

  @impl Solve
  def controllers() do
    [controller!(name: :chat, module: Epix.Chat.Controller)]
  end
end
