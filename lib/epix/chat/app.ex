defmodule Epix.Chat.App do
  @moduledoc """
  The Solve app hosting the chat controller graph. One controller for now.

  App params passed to `start_link(params: ...)` are forwarded to the controller,
  so a frontend can configure the session (e.g. `%{session_opts: [...]}`).
  """

  use Solve

  @impl Solve
  def controllers() do
    [
      controller!(
        name: :chat,
        module: Epix.Chat.Controller,
        params: fn %{app_params: app_params} -> app_params end
      )
    ]
  end
end
