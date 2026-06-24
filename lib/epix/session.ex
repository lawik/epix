defmodule Epix.Session do
  @moduledoc """
  Stateful shell around the pure loop: the imperative boundary.

  Owns the Lua sandbox and the running conversation context, and assembles the
  real effects (the req_llm model call and tool dispatch into the sandbox) that
  `Epix.Runner` drives. A plain `GenServer` for now, exposing `context/1` and
  `sandbox/1`. This is the seam where a `Solve` controller could later project
  richer session state to a TUI, GUI, API, or MCP frontend.

  Blocking note: a run occupies the GenServer until it finishes (`run/3` is a
  `:infinity` call), so cancellation/steering must be driven out of band via the
  `:abort`/`:steering` options rather than a separate call. Moving the run off the
  call path (a Task + reply-later) is the next step to expose `cancel/1`/`steer/2`.
  """

  use GenServer

  alias Epix.{Compaction, Loop, Model, ModelStream, Runner, SystemPrompt, Tools}
  alias Epix.Loop.Config
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
  def run(session, prompt, opts \\ []),
    do: GenServer.call(session, {:run, prompt, opts}, :infinity)

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

  # Numeric/threshold defaults come from the Config struct; opts override them.
  # Here we only supply the runtime-computed defaults (model/api_key/tools) and
  # override tool_execution to :sequential, because the Lua tools share the
  # sandbox registry (define then run); callers can opt into :parallel.
  defp build_config(opts) do
    opts
    |> Keyword.put_new_lazy(:model, &Model.berget/0)
    |> Keyword.put_new_lazy(:api_key, &Model.api_key/0)
    |> Keyword.put_new_lazy(:tools, &Tools.specs/0)
    |> Keyword.put_new(:tool_execution, :sequential)
    |> then(&struct(Config, &1))
  end

  @impl true
  def handle_call({:run, prompt, opts}, _from, %{config: config} = state) do
    context = Context.append(state.context, Context.user(prompt))
    loop_state = Loop.init(context, config)

    run_opts =
      [
        verbose: state.verbose,
        compaction: Keyword.get(opts, :compaction, compaction_fun(config))
      ] ++
        Keyword.take(opts, [
          :emit,
          :abort,
          :steering,
          :follow_up,
          :transform_context,
          :before_tool_call,
          :after_tool_call,
          :prepare_next_turn
        ])

    # Contain a crashing run (e.g. a raising hook outside tool dispatch) so it
    # returns an error and the session keeps its conversation rather than dying.
    {result, final} =
      Runner.run(loop_state, model_fun(config), tool_fun(state.sandbox), run_opts)

    {:reply, result, %{state | context: final.context}}
  rescue
    exception -> {:reply, {:error, {:run_crashed, Exception.message(exception)}}, state}
  catch
    kind, reason -> {:reply, {:error, {:run_crashed, {kind, reason}}}, state}
  end

  def handle_call(:context, _from, state), do: {:reply, state.context, state}
  def handle_call(:sandbox, _from, state), do: {:reply, state.sandbox, state}

  # --- effects (the imperative boundary) ---

  defp model_fun(config) do
    fn context, %Config{} = cfg, rctx ->
      ModelStream.run(fn -> request(config, cfg, context) end, rctx)
    end
  end

  defp request(config, cfg, context) do
    ReqLLM.stream_text(config.model, context,
      tools: cfg.tools,
      api_key: cfg.api_key,
      temperature: cfg.temperature,
      max_tokens: cfg.max_tokens,
      receive_timeout: cfg.receive_timeout
    )
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp tool_fun(sandbox) do
    fn call, _rctx ->
      args = decode_args(call.function.arguments)

      case Tools.dispatch(call.function.name, args, sandbox) do
        {:ok, text} -> text
        {:error, message} -> "ERROR: #{message}"
      end
    end
  end

  # Compaction is the pure `Epix.Compaction` strategy with a model-backed
  # summarizer injected (kept here because it is a real provider effect).
  defp compaction_fun(config) do
    Compaction.strategy(fn old -> summarize(old, config) end)
  end

  defp summarize(messages, config) do
    transcript =
      messages
      |> Enum.map_join("\n", fn m -> "#{m.role}: #{message_text(m)}" end)
      |> cap_transcript()

    prompt =
      "Summarize this conversation transcript concisely, preserving key facts, " <>
        "decisions, tool results, and open tasks:\n\n" <> transcript

    case ReqLLM.generate_text(config.model, Context.new([Context.user(prompt)]),
           api_key: config.api_key,
           max_tokens: 1024,
           receive_timeout: config.receive_timeout
         ) do
      {:ok, resp} -> {:ok, Response.text(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Keep the summarizer prompt bounded so compaction's own model call (which runs
  # precisely because the context is large) cannot itself overflow the window.
  defp cap_transcript(text, max_chars \\ 12_000) do
    if String.length(text) > max_chars do
      "...(earlier content elided)...\n" <> String.slice(text, -max_chars, max_chars)
    else
      text
    end
  end

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp message_text(_message), do: ""

  @doc false
  # Tool arguments arrive as a JSON string; malformed/empty defaults to an empty
  # map so a bad model emission degrades to a missing-arg error, not a crash.
  @spec decode_args(String.t() | nil) :: map()
  def decode_args(json) when json in [nil, ""], do: %{}

  def decode_args(json) do
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
