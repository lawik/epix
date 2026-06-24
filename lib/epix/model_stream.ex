defmodule Epix.ModelStream do
  @moduledoc """
  Turns a streaming provider request into a normalized `Epix.Loop.Turn`.

  The request runs in an isolated, monitored worker so the provider's
  StreamServer/MetadataHandle link to *it*, not the caller: killing the worker
  after the result (or to cancel) tears those down with no per-call leak, and a
  cancellation kills it mid-stream, aborting the in-flight HTTP request. The stream
  is tapped once to emit `{:text_delta}`/`{:reasoning_delta}` as chunks arrive,
  then built into the final turn in the same pass (a one-shot body cannot be
  consumed twice).

  The request is injected (`(-> {:ok, %ReqLLM.StreamResponse{}} | {:error, _})`),
  so this is testable without a provider: pass a function returning a hand-built
  `%ReqLLM.StreamResponse{}`.
  """

  alias Epix.Abort
  alias Epix.Loop.Turn
  alias ReqLLM.{Response, StreamResponse}

  @worker_timeout 30_000
  @poll_interval 50

  # `struct()` rather than StreamResponse.t()/Response.t(): those reference
  # LLMDB.Model.t() which is not in the dialyzer PLT (a transitive dep type).
  @type request :: (-> {:ok, struct()} | {:error, term()})
  @type rctx :: %{
          required(:emit) => (term() -> any()),
          required(:abort) => Abort.t(),
          optional(any()) => any()
        }

  @doc "Runs the request in an isolated worker and consumes it into a turn."
  @spec run(request(), rctx()) :: {:ok, Turn.t()} | {:error, term()}
  def run(request, rctx) when is_function(request, 0) do
    isolated(fn -> consume(request.(), rctx) end, rctx.abort)
  end

  @doc "Consumes a stream response into a turn, emitting deltas and honoring abort."
  @spec consume({:ok, struct()} | {:error, term()}, rctx()) ::
          {:ok, Turn.t()} | {:error, term()}
  def consume({:error, reason}, _rctx), do: {:error, reason}

  def consume({:ok, %StreamResponse{} = stream_response}, rctx) do
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

    # Backstop that does not depend on the throw tunneling through to_response.
    if Abort.cancelled?(rctx.abort), do: {:error, :cancelled}, else: result
  catch
    :throw, :epix_cancelled -> {:error, :cancelled}
  end

  @doc "Builds a turn from a completed provider response."
  @spec normalize(struct()) :: Turn.t()
  def normalize(%Response{} = resp) do
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

  @doc false
  @spec emit_chunk(map(), (term() -> any())) :: any()
  def emit_chunk(%{type: :content, text: text}, emit) when is_binary(text),
    do: emit.({:text_delta, text})

  def emit_chunk(%{type: :thinking, text: text}, emit) when is_binary(text),
    do: emit.({:reasoning_delta, text})

  def emit_chunk(_chunk, _emit), do: :ok

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # The stream's cancel is a GenServer.call; if the server already stopped it
  # raises an exit, which we swallow so cancellation still reports as cancelled.
  defp safe_cancel(stream_response) do
    stream_response.cancel.()
  catch
    :exit, _ -> :ok
  end

  defp isolated(fun, abort) do
    parent = self()

    {worker, ref} =
      spawn_monitor(fn ->
        # Exit if the parent dies mid-call so the worker (and the provider
        # processes linked to it) are not orphaned.
        parent_ref = Process.monitor(parent)
        send(parent, {:model_done, self(), fun.()})

        receive do
          :stop -> :ok
          {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
        after
          @worker_timeout -> :ok
        end
      end)

    result = await(worker, ref, abort)
    Process.exit(worker, :kill)
    Process.demonitor(ref, [:flush])
    # Drop a result the worker may have sent in the cancel race window so it does
    # not linger in the caller's mailbox.
    receive do
      {:model_done, ^worker, _} -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp await(worker, ref, abort) do
    receive do
      {:model_done, ^worker, result} -> result
      {:DOWN, ^ref, :process, ^worker, reason} -> {:error, {:model_crashed, reason}}
    after
      @poll_interval ->
        if Abort.cancelled?(abort), do: {:error, :cancelled}, else: await(worker, ref, abort)
    end
  end
end
