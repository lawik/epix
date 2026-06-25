defmodule Epix.Command do
  @moduledoc """
  A descriptor for an operator command: a frontend-agnostic action on a session,
  the human/operator counterpart to a model-facing `Epix.Tools` spec.

  Frontends render and expose these from `Epix.Commands.specs/0` — a TUI as slash
  commands, a GUI as buttons, an HTTP API as endpoints, an MCP server as tools —
  and invoke them via `Epix.Commands.dispatch/3`. The `args` are described
  abstractly (name/type/required) so each frontend can generate its own input
  surface (a usage string, a form, a JSON schema).
  """

  @enforce_keys [:name, :summary]
  defstruct [:name, :summary, args: []]

  @type arg :: %{
          name: String.t(),
          type: :string | :string_list,
          required: boolean(),
          summary: String.t()
        }
  @type t :: %__MODULE__{name: String.t(), summary: String.t(), args: [arg()]}
end
