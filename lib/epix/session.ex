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

  alias Epix.{Abort, Loop, Model, Runner, SystemPrompt, Tools}
  alias Epix.Loop.{Config, Turn}
  alias Epix.Lua.Sandbox
  alias ReqLLM.{Context, Response, StreamResponse}

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

    {result, final} =
      Runner.run(loop_state, model_fun(config), tool_fun(state.sandbox), run_opts)

    {:reply, result, %{state | context: final.context}}
  end

  def handle_call(:context, _from, state), do: {:reply, state.context, state}
  def handle_call(:sandbox, _from, state), do: {:reply, state.sandbox, state}

  # --- effects (the imperative boundary) ---

  defp model_fun(config) do
    fn context, %Config{} = cfg, rctx ->
      isolated_call(fn -> stream_call(config, cfg, context, rctx) end, rctx.abort)
    end
  end

  defp stream_call(config, cfg, context, rctx) do
    case ReqLLM.stream_text(config.model, context,
           tools: cfg.tools,
           api_key: cfg.api_key,
           temperature: cfg.temperature,
           max_tokens: cfg.max_tokens,
           receive_timeout: cfg.receive_timeout
         ) do
      {:ok, stream_response} -> consume_stream(stream_response, rctx)
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # Run the model call in an isolated, monitored (unlinked) process so the
  # provider's StreamServer/MetadataHandle link to *it*, not the Session. Once the
  # result is in hand the worker is killed, tearing those down (no per-call leak);
  # a cancellation kills it mid-stream, aborting the in-flight HTTP request.
  defp isolated_call(fun, abort) do
    parent = self()

    {worker, ref} =
      spawn_monitor(fn ->
        # Exit if the Session dies mid-call so the worker (and the provider
        # processes linked to it) are not orphaned.
        parent_ref = Process.monitor(parent)
        send(parent, {:model_done, self(), fun.()})

        receive do
          :stop -> :ok
          {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
        after
          30_000 -> :ok
        end
      end)

    result = await_isolated(worker, ref, abort)
    Process.exit(worker, :kill)
    Process.demonitor(ref, [:flush])
    # The worker may have sent its result in the cancel race window; drop it so it
    # does not linger in the Session mailbox.
    receive do
      {:model_done, ^worker, _} -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp await_isolated(worker, ref, abort) do
    receive do
      {:model_done, ^worker, result} -> result
      {:DOWN, ^ref, :process, ^worker, reason} -> {:error, {:model_crashed, reason}}
    after
      50 ->
        if Abort.cancelled?(abort),
          do: {:error, :cancelled},
          else: await_isolated(worker, ref, abort)
    end
  end

  # Tap the stream once: emit deltas as chunks arrive, then let `to_response`
  # drive the same tapped stream to build the final turn. Consuming the stream
  # twice would fail (one-shot HTTP body), so the tap and the build share one pass.
  #
  # The tap also checks the abort token per chunk: on cancellation it calls the
  # stream's own `cancel` for a graceful teardown (no killed-process log) and
  # throws past `to_response` (whose catch only handles `:exit`, not `:throw`).
  # As a backstop that does not depend on that dep detail, the token is re-checked
  # after `to_response` returns and any result is normalized to `:cancelled`.
  defp consume_stream(stream_response, rctx) do
    tapped =
      Stream.each(stream_response.stream, fn chunk ->
        if Abort.cancelled?(rctx.abort) do
          safe_cancel(stream_response)
          throw(:epix_cancelled)
        end

        emit_chunk(chunk, rctx.emit)
      end)

    result =
      case StreamResponse.to_response(%{stream_response | stream: tapped}) do
        {:ok, %Response{} = resp} -> {:ok, normalize(resp)}
        {:error, reason} -> {:error, reason}
      end

    if Abort.cancelled?(rctx.abort), do: {:error, :cancelled}, else: result
  catch
    :throw, :epix_cancelled -> {:error, :cancelled}
  end

  # The stream's cancel is a GenServer.call; if the server already stopped it
  # raises an exit, which we swallow so cancellation still reports as cancelled.
  defp safe_cancel(stream_response) do
    stream_response.cancel.()
  catch
    :exit, _ -> :ok
  end

  defp emit_chunk(%{type: :content, text: text}, emit) when is_binary(text),
    do: emit.({:text_delta, text})

  defp emit_chunk(%{type: :thinking, text: text}, emit) when is_binary(text),
    do: emit.({:reasoning_delta, text})

  defp emit_chunk(_chunk, _emit), do: :ok

  defp normalize(%Response{} = resp) do
    %Turn{
      message: resp.message,
      tool_calls: Response.tool_calls(resp),
      # A tool-call-only turn has empty content; normalize "" to nil so a
      # max_steps halt surfaces {:ok, nil} rather than masking it as {:ok, ""}.
      text: blank_to_nil(Response.text(resp)),
      finish_reason: Response.finish_reason(resp),
      usage: Response.usage(resp)
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp tool_fun(sandbox) do
    fn call, _rctx ->
      args = decode_args(call.function.arguments)

      case Tools.dispatch(call.function.name, args, sandbox) do
        {:ok, text} -> text
        {:error, message} -> "ERROR: #{message}"
      end
    end
  end

  # Compaction strategy: keep the system message and the current turn (from the
  # last user message), summarizing the older complete turns into one message. The
  # last-user boundary avoids splitting an assistant tool-call from its results.
  defp compaction_fun(config) do
    fn messages ->
      {system, rest} = pop_system(messages)
      compact_messages(messages, system, split_at_last_user(rest), config)
    end
  end

  defp compact_messages(messages, _system, {[], _recent}, _config), do: {:ok, messages}

  defp compact_messages(_messages, system, {old, recent}, config) do
    case summarize(old, config) do
      {:ok, text} ->
        summary = Context.user("[Summary of earlier conversation]\n" <> text)
        {:ok, system ++ [summary | recent]}

      {:error, _} = error ->
        error
    end
  end

  defp pop_system([%{role: :system} = system | rest]), do: {[system], rest}
  defp pop_system(messages), do: {[], messages}

  defp split_at_last_user(messages) do
    last_user =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {message, _index} -> message.role == :user end)
      |> List.last()

    case last_user do
      nil -> {messages, []}
      {_message, index} -> Enum.split(messages, index)
    end
  end

  defp summarize(messages, config) do
    transcript = Enum.map_join(messages, "\n", fn m -> "#{m.role}: #{message_text(m)}" end)

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

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp message_text(_message), do: ""

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
