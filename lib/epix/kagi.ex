defmodule Epix.Kagi do
  @moduledoc """
  A thin client for the [Kagi API](https://help.kagi.com/kagi/api/), exposing the
  two capabilities Epix needs: web **search** and **clean page fetching**.

  Both go through Kagi's v1 API (`https://kagi.com/api/v1`), authenticated with a
  bearer key minted at <https://kagi.com/api/keys>. Configuration is explicit: the
  key is passed per call as `:api_key`, and this module never reads the
  environment on its own. `from_env/0` sources the key from `KAGI_API_KEY` for dev
  tools and tests — e.g. `Epix.start_session(web: Epix.Kagi.from_env())`.

      iex> Epix.Kagi.search("elixir lang")
      {:ok, [%{url: "https://elixir-lang.org", title: "Elixir", snippet: "...", published: nil}]}

      iex> Epix.Kagi.fetch("https://elixir-lang.org")
      {:ok, "# The Elixir programming language\\n\\n..."}

  `search/2` returns the results of Kagi's default search workflow, each
  normalized to a small map. `fetch/2` runs a page through Kagi's Extract
  endpoint, which strips navigation, ads, and other boilerplate and hands back
  clean Markdown.

  On a non-success HTTP status both return `{:error, %Epix.Kagi.Error{}}`; on a
  transport failure they return `{:error, exception}` straight from Req.

  ## Options

  Both functions accept:

    * `:api_key`     — overrides `KAGI_API_KEY`
    * `:base_url`    — overrides the API base (`https://kagi.com/api/v1`)
    * `:req_options` — extra options merged into the underlying `Req` request

  `search/2` additionally accepts `:limit` (1–1024, default 10).
  """

  @base_url "https://kagi.com/api/v1"

  @type result :: %{
          url: String.t() | nil,
          title: String.t() | nil,
          snippet: String.t() | nil,
          published: String.t() | nil
        }

  @type error :: Epix.Kagi.Error.t() | Exception.t()

  @doc """
  Kagi options sourced from the environment, for dev tools and tests.

  Returns `[api_key: ...]` read from `KAGI_API_KEY`. The library never reads the
  environment itself; a caller opts in by splatting these (or passing its own
  `:api_key`) — e.g. `Epix.Kagi.search(query, Epix.Kagi.from_env())` or
  `Epix.start_session(web: Epix.Kagi.from_env())`.
  """
  @spec from_env() :: keyword()
  def from_env(), do: [api_key: System.get_env("KAGI_API_KEY")]

  @doc """
  Runs a web search for `query` and returns up to `:limit` normalized results.

  Each result is a map with `:url`, `:title`, `:snippet`, and `:published` (the
  resource's last-updated time, when Kagi reports one). Returns `{:ok, []}` when
  there are no matches.
  """
  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, error()}
  def search(query, opts \\ []) when is_binary(query) do
    body = %{query: query, limit: Keyword.get(opts, :limit, 10)}

    case request("/search", body, opts) do
      {:ok, response} ->
        results =
          (response["data"] || %{})
          |> Map.get("search", [])
          |> Enum.map(&to_result/1)

        {:ok, results}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Fetches `url` and returns its main content as clean Markdown.

  Uses Kagi's Extract endpoint, which removes boilerplate before converting the
  page. A URL that cannot be extracted yields `{:error, %Epix.Kagi.Error{}}`.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def fetch(url, opts \\ []) when is_binary(url) do
    case request("/extract", %{pages: [%{url: url}]}, opts) do
      {:ok, response} -> extracted(response)
      {:error, _reason} = error -> error
    end
  end

  defp to_result(result) when is_map(result) do
    %{
      url: result["url"],
      title: result["title"],
      snippet: result["snippet"],
      published: result["time"]
    }
  end

  # Extract returns one entry per requested page; we send a single page, so the
  # first entry carries either its `markdown` or a per-page `error`.
  defp extracted(response) do
    page = List.first(response["data"] || []) || %{}

    cond do
      is_binary(page["markdown"]) -> {:ok, page["markdown"]}
      is_binary(page["error"]) -> {:error, %Epix.Kagi.Error{details: [page]}}
      true -> {:error, %Epix.Kagi.Error{details: response["errors"] || []}}
    end
  end

  defp request(path, body, opts) do
    req =
      [
        method: :post,
        url: base_url(opts) <> path,
        auth: {:bearer, api_key!(opts)},
        json: body,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Epix.Kagi.Error{status: status, details: error_details(body)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp error_details(%{"error" => errors}) when is_list(errors), do: errors
  defp error_details(_body), do: []

  defp api_key!(opts) do
    opts[:api_key] ||
      raise ArgumentError,
            "no Kagi API key: pass :api_key (e.g. from Epix.Kagi.from_env/0)"
  end

  defp base_url(opts), do: opts[:base_url] || @base_url
end
