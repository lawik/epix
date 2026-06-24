defmodule Epix.Compaction do
  @moduledoc """
  Pure context-compaction strategy.

  Keeps the system message and the current turn (from the last user message — a
  boundary that never splits an assistant tool-call from its results) and replaces
  the older complete turns with a single summary message produced by an injected
  summarizer.

  The summarizer (`([message]) -> {:ok, text} | {:error, reason}`) is injected, so
  the strategy is fully testable without a model: `Epix.Session` supplies a
  model-backed one; tests pass a fake.
  """

  alias ReqLLM.Context

  @type message :: ReqLLM.Message.t()
  @type summarizer :: ([message()] -> {:ok, String.t()} | {:error, term()})

  @doc "Builds a compaction function (`[message] -> {:ok, [message]} | {:error, _}`)."
  @spec strategy(summarizer()) :: ([message()] -> {:ok, [message()]} | {:error, term()})
  def strategy(summarizer) when is_function(summarizer, 1) do
    fn messages -> compact(messages, summarizer) end
  end

  @doc "Compacts a message list with the given summarizer."
  @spec compact([message()], summarizer()) :: {:ok, [message()]} | {:error, term()}
  def compact(messages, summarizer) when is_function(summarizer, 1) do
    {system, rest} = pop_system(messages)

    case split_at_last_user(rest) do
      {[], _recent} ->
        {:ok, messages}

      {old, recent} ->
        case summarizer.(old) do
          {:ok, text} -> {:ok, system ++ [summary_message(text) | recent]}
          {:error, _} = error -> error
        end
    end
  end

  @doc "Splits off a leading system message, if present."
  @spec pop_system([message()]) :: {[message()], [message()]}
  def pop_system([%{role: :system} = system | rest]), do: {[system], rest}
  def pop_system(messages), do: {[], messages}

  @doc """
  Splits a message list at the last user message: `{older, current_turn}`.

  The current turn starts at a user message, so it never begins with an orphaned
  tool result, and `older` ends at a complete turn boundary.
  """
  @spec split_at_last_user([message()]) :: {[message()], [message()]}
  def split_at_last_user(messages) do
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

  defp summary_message(text), do: Context.user("[Summary of earlier conversation]\n" <> text)
end
