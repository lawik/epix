defmodule Epix.Tools do
  @moduledoc """
  The model-facing tool set (req_llm `Tool` structs) and the host-side dispatch.

  The model never executes anything directly: it emits tool calls, and the loop
  driver (`Epix.Runner` via `Epix.Session`) routes them through `dispatch/3` into
  the Lua sandbox. The req_llm `:callback` is unused (we drive execution
  ourselves), so it is a stub.
  """

  alias Epix.Lua.Sandbox
  alias ReqLLM.Tool

  @doc "Returns the list of req_llm tool definitions to advertise to the model."
  @spec specs() :: [Tool.t()]
  def specs() do
    [
      tool!(
        name: "lua_eval",
        description:
          "Evaluate a one-shot Lua snippet in the sandbox and return its result. " <>
            "Use `return X` to produce output. The `host` API is available. " <>
            "Compile and runtime errors are returned so you can fix and retry.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string", "description" => "Lua source to evaluate."}
          },
          "required" => ["code"]
        }
      ),
      tool!(
        name: "lua_define_tool",
        description:
          "Define a reusable Lua tool and store it for later use. The body is a Lua " <>
            "function body: parameters are in scope as locals, the `host` API is " <>
            "available, and `return` produces the result. Validated for compile errors.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Identifier for the tool."},
            "description" => %{"type" => "string", "description" => "What the tool does."},
            "params" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Ordered parameter names usable as locals in the body."
            },
            "code" => %{"type" => "string", "description" => "Lua function body."}
          },
          "required" => ["name", "description", "code"]
        }
      ),
      tool!(
        name: "lua_run_tool",
        description: "Run a previously defined Lua tool by name with an argument map.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Name of a defined tool."},
            "arguments" => %{
              "type" => "object",
              "description" => "Map of parameter name to value.",
              "additionalProperties" => true
            }
          },
          "required" => ["name"]
        }
      ),
      tool!(
        name: "lua_list_tools",
        description: "List the Lua tools that have been defined so far.",
        parameter_schema: %{"type" => "object", "properties" => %{}}
      ),
      tool!(
        name: "list_namespaces",
        description:
          "List the storage namespaces you can currently access. Pass one of these " <>
            "as the `namespace` argument to the `store.*` functions in your Lua.",
        parameter_schema: %{"type" => "object", "properties" => %{}}
      )
    ]
  end

  @doc "Routes a tool call (by name) into the sandbox. Returns `{:ok | :error, text}`."
  @spec dispatch(String.t(), map(), GenServer.server()) ::
          {:ok, String.t()} | {:error, String.t()}
  def dispatch("lua_eval", %{"code" => code}, sandbox), do: Sandbox.eval(sandbox, code)

  def dispatch("lua_define_tool", args, sandbox) do
    case Sandbox.define_tool(
           sandbox,
           args["name"],
           args["description"] || "",
           args["params"] || [],
           args["code"] || ""
         ) do
      :ok -> {:ok, "Defined tool #{inspect(args["name"])}."}
      {:error, message} -> {:error, message}
    end
  end

  def dispatch("lua_run_tool", args, sandbox) do
    Sandbox.run_tool(sandbox, args["name"], args["arguments"] || %{})
  end

  def dispatch("lua_list_tools", _args, sandbox) do
    case Sandbox.list_tools(sandbox) do
      [] ->
        {:ok, "No tools defined yet."}

      tools ->
        {:ok,
         Enum.map_join(tools, "\n", fn t ->
           "- #{t.name}(#{Enum.join(t.params, ", ")}): #{t.description}"
         end)}
    end
  end

  def dispatch("list_namespaces", _args, sandbox) do
    case Sandbox.namespaces(sandbox) do
      [] -> {:ok, "No namespaces are currently accessible."}
      namespaces -> {:ok, Enum.map_join(namespaces, "\n", &"- #{&1}")}
    end
  end

  def dispatch(name, _args, _sandbox), do: {:error, "unknown tool: #{name}"}

  defp tool!(opts) do
    Tool.new!(Keyword.put(opts, :callback, &__MODULE__.stub/1))
  end

  @doc false
  # Unused: the agent loop drives execution via dispatch/3, not req_llm callbacks.
  @spec stub(map()) :: {:error, String.t()}
  def stub(_args), do: {:error, "dispatched by host"}
end
