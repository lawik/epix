defmodule Epix.Lua.WebApiTest do
  @moduledoc "Exercises the Lua-facing `web` API end to end through the Sandbox."
  use ExUnit.Case, async: true

  alias Epix.Lua.Sandbox

  # Starts a sandbox with `web` enabled, its Kagi calls short-circuited by a Req
  # `:adapter` so nothing touches the network.
  defp start_web(adapter) do
    {:ok, s} =
      Sandbox.start_link(
        web: [api_key: "test-key", req_options: [adapter: adapter, retry: false]]
      )

    s
  end

  defp ok(status, body), do: Req.Response.new(status: status, body: body)

  test "search returns a list of result tables" do
    body = %{
      "data" => %{
        "search" => [
          %{"url" => "https://elixir-lang.org", "title" => "Elixir", "snippet" => "Functional"},
          %{"url" => "https://hexdocs.pm", "title" => "HexDocs"}
        ]
      }
    }

    s = start_web(fn req -> {req, ok(200, body)} end)

    assert {:ok, "2"} = Sandbox.eval(s, ~s|return #web.search("elixir")|)
    assert {:ok, ~s("Elixir")} = Sandbox.eval(s, ~s|return web.search("elixir")[1].title|)
    assert {:ok, ~s("Functional")} = Sandbox.eval(s, ~s|return web.search("elixir")[1].snippet|)

    assert {:ok, ~s("https://hexdocs.pm")} =
             Sandbox.eval(s, ~s|return web.search("elixir")[2].url|)
  end

  test "search forwards a numeric limit to Kagi" do
    test = self()

    adapter = fn req ->
      send(test, {:body, Jason.decode!(IO.iodata_to_binary(req.body))})
      {req, ok(200, %{"data" => %{"search" => []}})}
    end

    s = start_web(adapter)

    assert {:ok, "0"} = Sandbox.eval(s, ~s|return #web.search("x", 3)|)
    assert_received {:body, body}
    assert body["query"] == "x"
    assert body["limit"] == 3
  end

  test "fetch returns clean markdown" do
    body = %{"data" => [%{"url" => "https://ex.com", "markdown" => "# Title\n\nBody"}]}
    s = start_web(fn req -> {req, ok(200, body)} end)

    assert {:ok, json} = Sandbox.eval(s, ~s|return web.fetch("https://ex.com")|)
    assert Jason.decode!(json) == "# Title\n\nBody"
  end

  test "an API error surfaces as a readable Lua error" do
    body = %{"error" => [%{"code" => "auth.invalid", "message" => "Invalid API key"}]}
    s = start_web(fn req -> {req, ok(401, body)} end)

    assert {:error, message} = Sandbox.eval(s, ~s|return web.search("x")|)
    assert message =~ "web.search failed"
    assert message =~ "Invalid API key"
  end

  test "bad arguments raise a usage error" do
    s = start_web(fn req -> {req, ok(200, %{"data" => %{}})} end)
    assert {:error, message} = Sandbox.eval(s, ~s|return web.fetch()|)
    assert message =~ "web.fetch expects (url)"
  end

  test "without web enabled, the web table is absent" do
    {:ok, plain} = Sandbox.start_link()
    assert {:error, _} = Sandbox.eval(plain, ~s|return web.search("x")|)
  end
end
