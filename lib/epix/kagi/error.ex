defmodule Epix.Kagi.Error do
  @moduledoc """
  An error from the Kagi API: a non-success HTTP status, or a page that could
  not be extracted.

  `:status` is the HTTP status (`nil` for a per-page extraction failure, which
  arrives inside an otherwise-successful response) and `:details` holds Kagi's
  raw error maps verbatim, so callers can inspect codes and messages.
  """

  defexception status: nil, details: []

  @type t :: %__MODULE__{status: pos_integer() | nil, details: [map()]}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{status: status, details: details}) do
    summary =
      details
      |> Enum.map(fn detail -> detail["message"] || detail["error"] || detail["code"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    ["Kagi API error", status && "(HTTP #{status})", summary != "" && summary]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end
end
