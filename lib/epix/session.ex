defmodule Epix.Session do
  @moduledoc """
  Stateful shell around the pure loop: the imperative boundary.

  Owns the Lua sandbox and the running conversation context, and assembles the
  real effects (the req_llm model call and tool dispatch into the sandbox) that
  `Epix.Runner` drives. A plain `GenServer`, exposing `context/1`, `sandbox/1`, and
  the storage-namespace controls. This is the seam where a `Solve` controller could
  project richer session state to a frontend.

  The run executes off the GenServer call path (in a monitored worker, replying
  via `GenServer.reply` when done), so the Session stays responsive during a run:
  `cancel/1`, `steer/2`, `set_namespaces/2`, and `context/1` are answerable mid-run.
  """

  use GenServer

  alias Epix.{Abort, Compaction, Loop, Model, ModelStream, Runner, SystemPrompt, Tools}
  alias Epix.Loop.Config
  alias Epix.Lua.Sandbox
  alias ReqLLM.{Context, Response}

  @type t :: GenServer.server()

  # --- client API ---

  @doc """
  Starts a session.

  Options: `:model`, `:api_key`, `:sandbox` (reuse one), `:store` (an `Epix.Store`
  to enable the Lua `store` API), `:namespaces` (the storage namespaces this agent
  may access, default `[]`), `:max_steps`, `:temperature`, `:max_tokens`,
  `:receive_timeout` (per-request HTTP timeout, ms, default 60_000), `:verbose`,
  `:system_prompt`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Sends a user prompt and runs the loop to completion.

  The caller blocks until the run finishes, but the run executes off the GenServer
  call path, so `cancel/1` and `steer/2` (and `context/1`) are answerable mid-run
  from another process. Only one run at a time; a second returns `{:error, :busy}`.

  Options: `:emit` (`Epix.Event.emit`) plus any `Epix.Runner` hook options. The
  Session owns the `:abort`/`:steering` machinery, so those are driven via
  `cancel/1`/`steer/2`, not options.
  """
  @spec run(t(), String.t(), keyword()) :: Loop.result() | {:error, :busy}
  def run(session, prompt, opts \\ []),
    do: GenServer.call(session, {:run, prompt, opts}, :infinity)

  @doc "Cancels the in-flight run, if any. Returns `:ok` or `{:error, :idle}`."
  @spec cancel(t()) :: :ok | {:error, :idle}
  def cancel(session), do: GenServer.call(session, :cancel)

  @doc "Injects a user message into the in-flight run before its next model call."
  @spec steer(t(), String.t()) :: :ok | {:error, :idle}
  def steer(session, message), do: GenServer.call(session, {:steer, message})

  @doc "Returns the current conversation context."
  @spec context(t()) :: Context.t()
  def context(session), do: GenServer.call(session, :context)

  @doc "Returns the session's Lua sandbox pid."
  @spec sandbox(t()) :: pid()
  def sandbox(session), do: GenServer.call(session, :sandbox)

  @doc "Replaces the storage namespaces this agent's Lua may access (effective immediately)."
  @spec set_namespaces(t(), [String.t()]) :: :ok
  def set_namespaces(session, namespaces),
    do: GenServer.call(session, {:set_namespaces, namespaces})

  @doc "Returns the storage namespaces currently accessible to the agent."
  @spec namespaces(t()) :: [String.t()]
  def namespaces(session), do: GenServer.call(session, :namespaces)

  # --- server ---

  @impl true
  def init(opts) do
    system = opts[:system_prompt] || SystemPrompt.build(storage: opts[:store] != nil)
    context = Context.new([Context.system(system)])

    state = %{
      sandbox: opts[:sandbox] || start_sandbox!(opts),
      context: context,
      config: build_config(opts),
      verbose: opts[:verbose] || false,
      # Effect overrides (advanced/testing): a custom model_fun/tool_fun replaces
      # the real req_llm/sandbox effects, making the orchestration testable offline.
      model_fun: opts[:model_fun],
      tool_fun: opts[:tool_fun],
      run: nil
    }

    {:ok, state}
  end

  # Numeric/threshold defaults come from the Config struct; opts override them.
  # Here we only supply the runtime-computed defaults (model/api_key/tools) and
  # override tool_execution to :sequential, because the Lua tools share the
  # sandbox registry (define then run); callers can opt into :parallel.
  defp build_config(opts) do
    opts
    |> Keyword.put_new_lazy(:model, &Model.default/0)
    |> Keyword.put_new_lazy(:api_key, &Model.api_key/0)
    |> Keyword.put_new_lazy(:tools, &Tools.specs/0)
    |> Keyword.put_new(:tool_execution, :sequential)
    |> then(&struct(Config, &1))
  end

  @impl true
  def handle_call({:run, _prompt, _opts}, _from, %{run: run} = state) when run != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, prompt, opts}, from, %{config: config} = state) do
    loop_state = Loop.init(Context.append(state.context, Context.user(prompt)), config)
    abort = Abort.new()
    {:ok, steer} = Agent.start_link(fn -> [] end)
    run_opts = run_opts(state, config, opts, abort, steer)
    session = self()

    model_fun = state.model_fun || model_fun(config)
    tool_fun = state.tool_fun || tool_fun(state.sandbox)

    {pid, ref} =
      spawn_monitor(fn ->
        {result, final} = safe_run(loop_state, model_fun, tool_fun, run_opts)
        send(session, {:run_done, result, final.context})
      end)

    {:noreply, %{state | run: %{from: from, pid: pid, ref: ref, abort: abort, steer: steer}}}
  end

  def handle_call(:cancel, _from, %{run: nil} = state), do: {:reply, {:error, :idle}, state}

  def handle_call(:cancel, _from, %{run: run} = state) do
    Abort.cancel(run.abort)
    {:reply, :ok, state}
  end

  def handle_call({:steer, _message}, _from, %{run: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call({:steer, message}, _from, %{run: run} = state) do
    Agent.update(run.steer, &(&1 ++ [message]))
    {:reply, :ok, state}
  end

  def handle_call(:context, _from, state), do: {:reply, state.context, state}
  def handle_call(:sandbox, _from, state), do: {:reply, state.sandbox, state}

  def handle_call({:set_namespaces, namespaces}, _from, state) do
    {:reply, Sandbox.set_namespaces(state.sandbox, namespaces), state}
  end

  def handle_call(:namespaces, _from, state) do
    {:reply, Sandbox.namespaces(state.sandbox), state}
  end

  @impl true
  def handle_info({:run_done, result, context}, %{run: run} = state) when run != nil do
    GenServer.reply(run.from, result)
    Process.demonitor(run.ref, [:flush])
    Agent.stop(run.steer)
    {:noreply, %{state | context: context, run: nil}}
  end

  # The run process crashed before reporting (safe_run should prevent this).
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{ref: ref} = run} = state) do
    GenServer.reply(run.from, {:error, {:run_crashed, reason}})
    Agent.stop(run.steer)
    {:noreply, %{state | run: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The Session owns abort + steering so cancel/2 and steer/2 work; the caller's
  # other hook options pass through.
  defp run_opts(state, config, opts, abort, steer) do
    [
      verbose: state.verbose,
      abort: abort,
      steering: fn -> Agent.get_and_update(steer, &{&1, []}) end,
      compaction: Keyword.get(opts, :compaction, compaction_fun(config))
    ] ++
      Keyword.take(opts, [
        :emit,
        :follow_up,
        :transform_context,
        :before_tool_call,
        :after_tool_call,
        :prepare_next_turn
      ])
  end

  # Contain a crashing run (e.g. a raising hook outside tool dispatch) so it
  # returns an error and the session keeps its conversation rather than dying.
  defp safe_run(loop_state, model_fun, tool_fun, run_opts) do
    Runner.run(loop_state, model_fun, tool_fun, run_opts)
  rescue
    exception -> {{:error, {:run_crashed, Exception.message(exception)}}, loop_state}
  catch
    kind, reason -> {{:error, {:run_crashed, {kind, reason}}}, loop_state}
  end

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

  defp start_sandbox!(opts) do
    {:ok, pid} = Sandbox.start_link(store: opts[:store], namespaces: opts[:namespaces] || [])
    pid
  end
end
