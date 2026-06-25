defmodule Epix.Lua.WebApi do
  @moduledoc """
  Installs the `web` table into a Lua state: the agent's web search and clean
  page-fetch interop, backed by `Epix.Kagi`.

  `web.search` returns a list of result tables; `web.fetch` returns a page's main
  content as clean Markdown. Both reach the live network through `Epix.Kagi`, so
  they need a Kagi key (see `Epix.Kagi`). The functions close over the options the
  host installed them with — which is also where a future rate limiter would sit.

  Any failure (bad arguments, an API error, a transport failure, or a missing
  key) raises a Lua error carrying Kagi's message, so the model can read it and
  retry rather than getting a silent nil.
  """

  alias Epix.Kagi

  @type opts :: keyword()

  @doc "Installs `web.*` into a Lua state, forwarding `opts` to `Epix.Kagi`."
  @spec install(Lua.t(), opts()) :: Lua.t()
  def install(%Lua{} = lua, opts \\ []) do
    lua
    |> Lua.set!(["web", "search"], search_fun(opts))
    |> Lua.set!(["web", "fetch"], fetch_fun(opts))
  end

  @doc "Renders the web API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    """
    - `web.search(query[, limit])` — search the web. Returns a list of results,
      each a table with `url`, `title`, `snippet`, and `published` fields.
    - `web.fetch(url)` — fetch a page and return its main content as clean
      Markdown, with navigation, ads, and other boilerplate removed.

    Both reach the live network and can fail (rate limits, an unreachable page);
    on failure they raise an error you can read and retry.
    """
  end

  defp search_fun(opts) do
    fn
      [query], lua when is_binary(query) ->
        search(lua, query, opts)

      [query, limit], lua when is_binary(query) and is_number(limit) ->
        search(lua, query, Keyword.put(opts, :limit, trunc(limit)))

      _args, _lua ->
        raise Lua.RuntimeException, "web.search expects (query) or (query, limit)"
    end
  end

  defp fetch_fun(opts) do
    fn
      [url], lua when is_binary(url) ->
        fetch(lua, url, opts)

      _args, _lua ->
        raise Lua.RuntimeException, "web.fetch expects (url)"
    end
  end

  defp search(lua, query, opts) do
    case call(fn -> Kagi.search(query, opts) end) do
      {:ok, results} ->
        {encoded, lua} = Lua.encode!(lua, Enum.map(results, &result_table/1))
        {[encoded], lua}

      {:error, message} ->
        raise Lua.RuntimeException, "web.search failed: " <> message
    end
  end

  defp fetch(lua, url, opts) do
    case call(fn -> Kagi.fetch(url, opts) end) do
      {:ok, markdown} -> {[markdown], lua}
      {:error, message} -> raise Lua.RuntimeException, "web.fetch failed: " <> message
    end
  end

  # Runs a Kagi call, normalizing every failure to {:error, message}: a returned
  # error (API/transport, both exceptions) or a raised ArgumentError (e.g. no key).
  defp call(fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  # Lua tables use string keys; drop nil fields so the model sees only what is
  # present (url/title are always set; snippet/published may be absent).
  defp result_table(result) do
    %{"url" => result.url, "title" => result.title}
    |> put_present("snippet", result.snippet)
    |> put_present("published", result.published)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
