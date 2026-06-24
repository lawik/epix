defmodule Epix.Session do
  @moduledoc """
  Stateful shell around the pure loop: the imperative boundary.

  Owns the Lua sandbox and the running conversation context, and assembles the
  real effects (the req_llm model call and tool dispatch into the sandbox) that
  `Epix.Runner` drives. A plain `GenServer` for now. This is the seam where a
  `Solve` controller could later expose session state (messages, defined tools,
  running?, usage) to a TUI, GUI, API, or MCP frontend, all of which would
  observe the same building blocks underneath.

  Blocking note: a run occupies the GenServer until it finishes. That is fine for
  a single session; mid-run steering would move the model call off the call path.
  """

  use GenServer

  alias Epix.{Loop, Model, Runner, SystemPrompt, Tools}
  alias Epix.Loop.{Config, Turn}
  alias Epix.Lua.Sandbox
  alias ReqLLM.{Context, Response}

  @type t :: GenServer.server()

  # --- client API ---

  @doc """
  Starts a session.

  Options: `:model`, `:api_key`, `:sandbox` (reuse one), `:max_steps`,
  `:temperature`, `:max_tokens`, `:receive_timeout` (per-request HTTP timeout, ms,
  default 60_000), `:verbose`, `:system_prompt`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Sends a user prompt and runs the loop to completion.

  Options: `:emit` (`Epix.Event.emit`) to observe progress during the run.
  """
  @spec run(t(), String.t(), keyword()) :: Loop.result()
  def run(session, prompt, opts \\ []), do: GenServer.call(session, {:run, prompt, opts}, :infinity)

  @doc "Returns the current conversation context."
  @spec context(t()) :: Context.t()
  def context(session), do: GenServer.call(session, :context)

  @doc "Returns the session's Lua sandbox pid."
  @spec sandbox(t()) :: pid()
  def sandbox(session), do: GenServer.call(session, :sandbox)

  # --- server ---

  @impl true
  def init(opts) do
    context = Context.new([Context.system(opts[:system_prompt] || SystemPrompt.build())])

    state = %{
      sandbox: opts[:sandbox] || start_sandbox!(),
      context: context,
      config: build_config(opts),
      verbose: opts[:verbose] || false
    }

    {:ok, state}
  end

  defp build_config(opts) do
    %Config{
      model: opts[:model] || Model.berget(),
      api_key: opts[:api_key] || Model.api_key(),
      tools: Tools.specs(),
      max_steps: opts[:max_steps] || 8,
      temperature: opts[:temperature] || 0.2,
      max_tokens: opts[:max_tokens] || 1024,
      receive_timeout: opts[:receive_timeout] || 60_000
    }
  end

  @impl true
  def handle_call({:run, prompt, opts}, _from, %{config: config} = state) do
    context = Context.append(state.context, Context.user(prompt))
    loop_state = Loop.init(context, config)

    run_opts = [verbose: state.verbose] ++ Keyword.take(opts, [:emit])

    {result, final} =
      Runner.run(loop_state, model_fun(config), tool_fun(state.sandbox), run_opts)

    {:reply, result, %{state | context: final.context}}
  end

  def handle_call(:context, _from, state), do: {:reply, state.context, state}
  def handle_call(:sandbox, _from, state), do: {:reply, state.sandbox, state}

  # --- effects (the imperative boundary) ---

  defp model_fun(config) do
    fn context, %Config{} = cfg ->
      try do
        case ReqLLM.generate_text(config.model, context,
               tools: cfg.tools,
               api_key: cfg.api_key,
               temperature: cfg.temperature,
               max_tokens: cfg.max_tokens,
               receive_timeout: cfg.receive_timeout
             ) do
          {:ok, resp} -> {:ok, normalize(resp)}
          {:error, reason} -> {:error, reason}
        end
      rescue
        exception -> {:error, Exception.message(exception)}
      end
    end
  end

  defp normalize(%Response{} = resp) do
    %Turn{
      message: resp.message,
      tool_calls: Response.tool_calls(resp),
      text: Response.text(resp),
      finish_reason: Response.finish_reason(resp),
      usage: Response.usage(resp)
    }
  end

  defp tool_fun(sandbox) do
    fn call ->
      args = decode_args(call.function.arguments)

      case Tools.dispatch(call.function.name, args, sandbox) do
        {:ok, text} -> text
        {:error, message} -> "ERROR: #{message}"
      end
    end
  end

  defp decode_args(json) when json in [nil, ""], do: %{}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp start_sandbox!() do
    {:ok, pid} = Sandbox.start_link()
    pid
  end
end
