defmodule Epix.Chat.ControllerTest do
  @moduledoc """
  Headless integration test of the Solve layer (App + Controller + Projection)
  with no TUI and no network: a fake model_fun is injected via the controller's
  session_opts, and we subscribe as a frontend would and dispatch a prompt.
  """
  use ExUnit.Case, async: true

  alias Epix.Chat.App
  alias Epix.Loop.Turn

  defp reply_model(text) do
    fn _ctx, _cfg, _rctx ->
      {:ok,
       %Turn{
         message: %ReqLLM.Message{role: :assistant, content: []},
         text: text,
         finish_reason: :stop
       }}
    end
  end

  defp start_app(model_fun) do
    {:ok, app} =
      App.start_link(name: nil, params: %{session_opts: [model_fun: model_fun, api_key: "test"]})

    app
  end

  # Collect pushed updates until the run is idle with the expected assistant reply.
  defp await_reply(text, deadline \\ 2_000) do
    receive do
      %Solve.Message{type: :update, payload: %Solve.Update{exposed_state: exposed}} ->
        if exposed.status == :idle and
             Enum.any?(exposed.messages, &(&1.role == :assistant and &1.text == text)) do
          exposed
        else
          await_reply(text, deadline)
        end
    after
      deadline -> flunk("did not receive an idle update with the assistant reply")
    end
  end

  test "subscribe returns the initial exposed state" do
    app = start_app(reply_model("hi"))

    assert Solve.subscribe(app, :chat, self()) ==
             %{messages: [], status: :idle, log: [], tokens: 0}
  end

  test "a dispatched prompt runs the loop and exposes the transcript and stage log" do
    app = start_app(reply_model("hello back"))
    assert %{messages: [], status: :idle} = Solve.subscribe(app, :chat, self())

    Solve.dispatch(app, :chat, :submit, %{text: "hi there"})

    final = await_reply("hello back")
    assert %{role: :user, text: "hi there"} in final.messages
    assert Enum.any?(final.messages, &(&1.role == :assistant and &1.text == "hello back"))
    # The stage log captured the request/response and the completion.
    assert Enum.any?(final.log, &String.starts_with?(&1, "→ request"))
    assert "■ done" in final.log
  end
end
