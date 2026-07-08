defmodule Epix.Session do
  @moduledoc """
  Stateful shell around the pure loop: the imperative boundary.

  Owns the Lua sandbox and the running conversation context, and assembles the
  real effects (the model call via the configured `Epix.Backend` and tool
  dispatch into the sandbox) that
  `Epix.Runner` drives. A plain `GenServer`, exposing `context/1`, `sandbox/1`, and
  the storage-namespace controls. This is the seam where a `Solve` controller could
  project richer session state to a frontend.

  The run executes off the GenServer call path (in a monitored worker, replying
  via `GenServer.reply` when done), so the Session stays responsive during a run:
  `cancel/1`, `steer/2`, `set_namespaces/2`, and `context/1` are answerable mid-run.
  """

  use GenServer

  alias Epix.{
    Abort,
    Compaction,
    Event,
    Git,
    Loop,
    Runner,
    SessionStore,
    SystemPrompt,
    Tools
  }

  alias Epix.Loop.Config
  alias Epix.Lua.{FsApi, GitApi, Sandbox}
  alias Epix.Runner.Ctx
  alias ReqLLM.Context

  require Logger

  # The model backend used when a caller passes neither :backend nor :model_fun.
  @default_backend Epix.Backend.ReqLLM

  @type t :: GenServer.server()

  # --- client API ---

  @doc """
  Starts a session.

  Configuration is explicit — the session reads no global/application env. Pass
  `:model` (a `ReqLLM` model; required to talk to a provider) and `:api_key`
  directly, or splat `Epix.Model.from_env/0` to source them from `EPIX_*` env in
  a dev tool or test. (Tests inject `:model_fun` instead and need neither.)

  To run inference somewhere other than req_llm, pass `:backend` — an
  `Epix.Backend` module (default `Epix.Backend.ReqLLM`). The backend interprets
  `:model`, so a local backend may take an on-device model handle rather than a
  `ReqLLM` model.

  Options: `:model`, `:backend`, `:api_key`, `:sandbox` (reuse one), `:store` (an `Epix.Store`
  to enable the Lua `kv` API), `:namespaces` (the storage namespaces this agent
  may access, default `[]`), `:web` (enable the Lua `web` API — search and clean
  page fetch — by passing a keyword list of `Epix.Kagi` options, e.g.
  `Epix.Kagi.from_env()` or `[api_key: key]`), `:git` (enable the Lua `git` API by
  passing a list of repo grants, each `%{name:, dir:, writable:}` — see
  `Epix.Lua.GitApi`), `:fs` (enable the Lua `fs` API — a virtual filesystem, one
  bare repo per namespace under a root dir — by passing the root path, e.g.
  `fs: "/var/epix/fs"`; see `Epix.Lua.FsApi`). Both `:git` and `:fs` are backed by
  the `git` executable and are disabled with a warning when the host has none.
  `:id` (the session id, default a
  fresh UUID), `:persist` (a base directory; the session is saved to its **own**
  CubDB at `<dir>/<id>` — a separate backend from any kv `:store` — after each run
  and capability change, and is resumed from there if it already exists),
  `:max_steps`, `:temperature`, `:max_tokens`,
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

  @doc """
  Clears the conversation back to a fresh start (keeping the system prompt, the
  sandbox, and storage). Refused while a run is in progress.
  """
  @spec reset(t()) :: :ok | {:error, :busy}
  def reset(session), do: GenServer.call(session, :reset)

  @doc "Reports session state: `running?`, the model id, accessible namespaces, and message count."
  @spec status(t()) :: %{
          running: boolean(),
          model: term(),
          namespaces: [String.t()],
          messages: non_neg_integer()
        }
  def status(session), do: GenServer.call(session, :status)

  @doc "Returns the session id (the key it persists/resumes under)."
  @spec id(t()) :: String.t()
  def id(session), do: GenServer.call(session, :id)

  @doc "Forces a save of the session now (no-op unless `:persist` was given)."
  @spec save(t()) :: :ok
  def save(session), do: GenServer.call(session, :save)

  # --- server ---

  @impl true
  def init(opts) do
    id = opts[:id] || generate_id()
    sandbox = opts[:sandbox] || start_sandbox!(opts)

    caps = capabilities(opts)

    system =
      opts[:system_prompt] ||
        SystemPrompt.build(
          storage: opts[:store] != nil,
          web: is_list(opts[:web]),
          git: caps.git,
          fs: caps.fs
        )

    # The session's own storage backend (its own CubDB), separate from any kv.
    session_db = open_session_db(opts[:persist], id)

    state = %{
      id: id,
      session_db: session_db,
      sandbox: sandbox,
      context: restore_or_new(session_db, sandbox, system),
      config: build_config(opts),
      verbose: opts[:verbose] || false,
      # The model backend (an `Epix.Backend` module); default req_llm. A custom
      # backend (e.g. an on-device model) is selected here.
      backend: opts[:backend] || @default_backend,
      # Effect overrides (advanced/testing): a custom model_fun/tool_fun replaces
      # the backend/sandbox effects, making the orchestration testable offline.
      model_fun: opts[:model_fun],
      tool_fun: opts[:tool_fun],
      run: nil
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{session_db: db}) when is_pid(db), do: CubDB.stop(db)
  def terminate(_reason, _state), do: :ok

  # Both `git` and `fs` are backed by the `git` executable, so each is enabled only
  # when it is configured *and* git is on PATH. A grant on a host without `git` is
  # almost certainly a misconfigured deployment, so warn (once, at start) and
  # disable the capability rather than failing to start.
  defp capabilities(opts) do
    git = GitApi.normalize(opts[:git]) != nil
    fs = FsApi.normalize(opts[:fs]) != nil
    available = Git.available?()

    if (git or fs) and not available do
      Logger.warning(
        "Epix.Session: git/fs capabilities were configured but no `git` executable " <>
          "was found on PATH; they are disabled for this session."
      )
    end

    %{git: git and available, fs: fs and available}
  end

  defp open_session_db(nil, _id), do: nil

  defp open_session_db(base_dir, id) do
    {:ok, db} = SessionStore.open(base_dir, id)
    db
  end

  # A new session starts with just the system prompt. A persisted one is resumed
  # from its own backend: its saved conversation is restored and its granted
  # namespaces re-applied (the kv data those namespaces hold persists separately).
  defp restore_or_new(nil, _sandbox, system), do: Context.new([Context.system(system)])

  defp restore_or_new(db, sandbox, system) do
    case SessionStore.load(db) do
      nil ->
        Context.new([Context.system(system)])

      record ->
        if record.namespaces != [], do: Sandbox.set_namespaces(sandbox, record.namespaces)
        Context.new(record.messages)
    end
  end

  # Numeric/threshold defaults come from the Config struct; opts override them.
  # The model and api_key are NOT defaulted here: a session reads no global
  # configuration, so the caller passes them explicitly (a dev tool or test can
  # source them from the environment via `Epix.Model.from_env/0`). We only supply
  # the built-in tool set and override tool_execution to :sequential, because the
  # Lua tools share the sandbox registry (define then run); callers can opt into
  # :parallel.
  defp build_config(opts) do
    opts
    |> Keyword.put_new_lazy(:tools, &Tools.specs/0)
    |> Keyword.put_new(:tool_execution, :sequential)
    |> then(&struct(Config, &1))
  end

  defp model_id(model) when is_struct(model), do: Map.get(model, :id)
  defp model_id(_model), do: nil

  @doc "Generates a random session id (UUID v4)."
  @spec generate_id() :: String.t()
  def generate_id() do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp persist(%{session_db: nil}), do: :ok

  defp persist(%{session_db: db, context: context, sandbox: sandbox}) do
    SessionStore.save(db, %{
      messages: context.messages,
      namespaces: Sandbox.namespaces(sandbox),
      updated_at: System.os_time(:second)
    })
  end

  @impl true
  def handle_call({:run, _prompt, _opts}, _from, %{run: run} = state) when run != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, prompt, opts}, from, %{config: config} = state) do
    loop_state = Loop.init(Context.append(state.context, Context.user(prompt)), config)
    abort = Abort.new()
    {:ok, steer} = Agent.start_link(fn -> [] end)
    session = self()

    model_fun = state.model_fun || backend_model_fun(state.backend)
    tool_fun = state.tool_fun || tool_fun(state.sandbox)
    run_opts = run_opts(state, config, opts, abort, steer, model_fun)

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
    reply = Sandbox.set_namespaces(state.sandbox, namespaces)
    persist(state)
    {:reply, reply, state}
  end

  def handle_call(:namespaces, _from, state) do
    {:reply, Sandbox.namespaces(state.sandbox), state}
  end

  def handle_call(:reset, _from, %{run: run} = state) when run != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:reset, _from, state) do
    [system | _rest] = state.context.messages
    state = %{state | context: Context.new([system])}
    persist(state)
    {:reply, :ok, state}
  end

  def handle_call(:id, _from, state), do: {:reply, state.id, state}

  def handle_call(:save, _from, state) do
    persist(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      running: state.run != nil,
      model: model_id(state.config.model),
      namespaces: Sandbox.namespaces(state.sandbox),
      messages: length(state.context.messages)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:run_done, result, context}, %{run: run} = state) when run != nil do
    GenServer.reply(run.from, result)
    Process.demonitor(run.ref, [:flush])
    Agent.stop(run.steer)
    state = %{state | context: context, run: nil}
    persist(state)
    {:noreply, state}
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
  defp run_opts(state, config, opts, abort, steer, model_fun) do
    [
      verbose: state.verbose,
      abort: abort,
      steering: fn -> Agent.get_and_update(steer, &{&1, []}) end,
      compaction: Keyword.get(opts, :compaction, compaction_fun(model_fun, config, abort))
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

  # The model effect is the configured backend's `call/3`, wrapped as a plain
  # function to match the Runner's model_fun contract. Tests override this
  # wholesale with :model_fun.
  defp backend_model_fun(backend) do
    fn context, %Config{} = cfg, rctx -> backend.call(context, cfg, rctx) end
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
  # summarizer injected. The summary runs through the same backend as the agent
  # (via model_fun), so a non-req_llm backend summarizes with its own model too.
  defp compaction_fun(model_fun, config, abort) do
    Compaction.strategy(fn old -> summarize(model_fun, config, abort, old) end)
  end

  defp summarize(model_fun, config, abort, messages) do
    transcript =
      messages
      |> Enum.map_join("\n", fn m -> "#{m.role}: #{message_text(m)}" end)
      |> cap_transcript()

    prompt =
      "Summarize this conversation transcript concisely, preserving key facts, " <>
        "decisions, tool results, and open tasks:\n\n" <> transcript

    ctx = %Ctx{emit: Event.noop(), abort: abort}

    case model_fun.(Context.new([Context.user(prompt)]), %{config | tools: []}, ctx) do
      {:ok, turn} -> {:ok, turn.text || ""}
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
    {:ok, pid} =
      Sandbox.start_link(
        store: opts[:store],
        namespaces: opts[:namespaces] || [],
        web: opts[:web],
        git: opts[:git],
        fs: opts[:fs]
      )

    pid
  end
end
