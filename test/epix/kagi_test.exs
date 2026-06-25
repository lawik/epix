defmodule Epix.KagiTest do
  use ExUnit.Case, async: true

  alias Epix.Kagi
  alias Epix.Kagi.Error

  # Builds call options that short-circuit the network: a Req `:adapter` records
  # the outgoing request to the test process and returns `response`. `retry:
  # false` keeps the adapter to a single, deterministic call.
  defp stub(response) do
    test = self()

    adapter = fn request ->
      send(test, {:request, request})
      {request, response}
    end

    [api_key: "test-key", req_options: [adapter: adapter, retry: false]]
  end

  defp response(status, body), do: Req.Response.new(status: status, body: body)

  defp sent_body do
    assert_received {:request, request}
    {request, Jason.decode!(IO.iodata_to_binary(request.body))}
  end

  describe "search/2" do
    test "posts the query and normalizes results" do
      body = %{
        "meta" => %{"ms" => 12},
        "data" => %{
          "search" => [
            %{
              "url" => "https://elixir-lang.org",
              "title" => "Elixir",
              "snippet" => "A dynamic, functional language",
              "time" => "2024-11-29T03:54:26Z"
            }
          ]
        }
      }

      assert {:ok, [result]} = Kagi.search("elixir", stub(response(200, body)) ++ [limit: 5])

      assert result == %{
               url: "https://elixir-lang.org",
               title: "Elixir",
               snippet: "A dynamic, functional language",
               published: "2024-11-29T03:54:26Z"
             }

      {request, decoded} = sent_body()
      assert request.method == :post
      assert to_string(request.url) =~ "/search"
      assert Req.Request.get_header(request, "authorization") == ["Bearer test-key"]
      assert decoded == %{"query" => "elixir", "limit" => 5}
    end

    test "defaults the limit to 10" do
      assert {:ok, []} = Kagi.search("anything", stub(response(200, %{"data" => %{}})))
      {_request, decoded} = sent_body()
      assert decoded["limit"] == 10
    end

    test "returns an empty list when there are no results" do
      assert {:ok, []} = Kagi.search("nothing here", stub(response(200, %{"data" => %{}})))
    end

    test "maps a non-success status to an Error with Kagi's details" do
      body = %{"error" => [%{"code" => "auth.invalid", "message" => "Invalid API key"}]}

      assert {:error, %Error{status: 401, details: [detail]}} =
               Kagi.search("x", stub(response(401, body)))

      assert detail["message"] == "Invalid API key"
    end

    test "passes a transport error through untouched" do
      adapter = fn request -> {request, %RuntimeError{message: "boom"}} end

      assert {:error, %RuntimeError{message: "boom"}} =
               Kagi.search("x", api_key: "k", req_options: [adapter: adapter, retry: false])
    end
  end

  describe "fetch/2" do
    test "returns clean markdown for the page" do
      body = %{"data" => [%{"url" => "https://ex.com", "markdown" => "# Title\n\nBody"}]}

      assert {:ok, "# Title\n\nBody"} = Kagi.fetch("https://ex.com", stub(response(200, body)))

      {request, decoded} = sent_body()
      assert request.method == :post
      assert to_string(request.url) =~ "/extract"
      assert decoded == %{"pages" => [%{"url" => "https://ex.com"}]}
    end

    test "surfaces a per-page extraction error" do
      body = %{"data" => [%{"url" => "https://ex.com", "markdown" => nil, "error" => "blocked"}]}

      assert {:error, %Error{status: nil, details: [detail]}} =
               Kagi.fetch("https://ex.com", stub(response(200, body)))

      assert detail["error"] == "blocked"
    end

    test "surfaces top-level extract errors" do
      body = %{
        "data" => [],
        "errors" => [%{"code" => "extract.timeout", "message" => "timed out"}]
      }

      assert {:error, %Error{details: [%{"code" => "extract.timeout"}]}} =
               Kagi.fetch("https://ex.com", stub(response(200, body)))
    end
  end

  describe "configuration" do
    test "raises a clear error when no API key is available" do
      prev = System.get_env("KAGI_API_KEY")
      System.delete_env("KAGI_API_KEY")
      on_exit(fn -> if prev, do: System.put_env("KAGI_API_KEY", prev) end)

      assert_raise ArgumentError, ~r/KAGI_API_KEY/, fn -> Kagi.search("x") end
    end
  end

  describe "Error.message/1" do
    test "summarizes the status and details" do
      message = Exception.message(%Error{status: 429, details: [%{"message" => "Rate limited"}]})
      assert message =~ "HTTP 429"
      assert message =~ "Rate limited"
    end

    test "renders without a status for per-page failures" do
      message = Exception.message(%Error{details: [%{"error" => "blocked"}]})
      assert message == "Kagi API error blocked"
    end
  end

  # Live tests hit the real Kagi API and cost credits, so they run only when a
  # real key is configured. test_helper.exs excludes the :kagi_live tag whenever
  # KAGI_API_KEY is unset.
  describe "live API" do
    @describetag :kagi_live

    test "search returns real results" do
      assert {:ok, [_ | _] = results} = Kagi.search("elixir programming language", limit: 3)
      assert Enum.all?(results, &is_binary(&1.url))
    end

    test "fetch returns markdown for a real page" do
      assert {:ok, markdown} = Kagi.fetch("https://elixir-lang.org")
      assert is_binary(markdown) and markdown != ""
    end
  end
end
