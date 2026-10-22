defmodule ColdForge.Sourcing.Fetcher do
  @moduledoc """
  Fetches one page, politely: robots.txt first, then the per-host gap, then the
  request itself with limits.

  The user agent says who we are and gives a way to tell us to stop. That isn't
  decoration — an operator who can see who is crawling and email about it is an
  operator who blocks us instead of blocking everyone, and we would honour the
  request. A crawler that hides is a crawler that deserves to be blocked.

  Returns `{:error, {:wait, ms}}` rather than sleeping when the host was hit
  too recently, so the caller can put the job back on the queue instead of
  holding a worker idle.
  """

  alias ColdForge.Sourcing.{Politeness, Robots}

  @user_agent "ColdForge/0.1 (+mailto:kris@affordablestartup.com; lead research; respects robots.txt)"

  # A contact page is a few kilobytes. Anything past this is a PDF, a video or
  # a misconfiguration, and none of them carry the address.
  @max_bytes 2_000_000
  @timeout_ms 15_000
  @max_redirects 3

  # Where a published address actually lives, in the order worth trying. The
  # homepage first because a footer address is the commonest case, then the
  # pages that exist to be written to. Stops as soon as one yields an address.
  @paths [
    "/",
    "/contact",
    "/contact-us",
    "/contact.html",
    "/about",
    "/about-us",
    "/staff",
    "/team"
  ]

  def user_agent, do: @user_agent
  def max_bytes, do: @max_bytes

  @doc """
  The URLs worth trying for one site, homepage first.

  Keeps the site's own path if it has one — a Places website of
  `https://example.test/contact` is already the page we want, so it goes first
  and the guesses follow.
  """
  @spec candidate_urls(String.t(), pos_integer()) :: [String.t()]
  def candidate_urls(website, limit \\ 4) when is_binary(website) do
    uri = URI.parse(website)
    base = %{uri | path: nil, query: nil, fragment: nil}

    given =
      case uri.path do
        nil -> []
        "/" -> []
        path -> [URI.to_string(%{base | path: path})]
      end

    guesses = Enum.map(@paths, &URI.to_string(%{base | path: &1}))

    (given ++ guesses) |> Enum.uniq() |> Enum.take(limit)
  end

  @doc """
  Fetches `url` if robots.txt permits and the host's gap has elapsed.

  Errors worth knowing apart:

    * `{:wait, ms}` — come back, don't give up
    * `:disallowed_by_robots` — never come back for this path
    * `{:not_html, type}` — fetched, but nothing to parse
    * `{:too_large, bytes}` — refused before downloading
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         {:ok, robots} <- robots_for(uri),
         :ok <- check_robots(robots, uri),
         :ok <- Politeness.reserve(uri.host, Robots.crawl_delay(robots, @user_agent)) do
      get(url)
    else
      {:wait, ms} -> {:error, {:wait, ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, uri}

      _ ->
        {:error, :bad_url}
    end
  end

  defp check_robots(robots, uri) do
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    if Robots.allowed?(robots, @user_agent, path),
      do: :ok,
      else: {:error, :disallowed_by_robots}
  end

  @doc """
  The host's robots.txt, from cache or fetched once.

  A 404 or a parse failure caches `nil`, meaning "no rules, go ahead" — the
  convention, and treating a missing file as a block would make most of the web
  uncrawlable. A 5xx is cached as nil too: a host whose robots.txt is broken
  shouldn't be re-asked on every page of a crawl.
  """
  @spec robots_for(URI.t()) :: {:ok, Robots.t() | nil} | {:error, term()}
  def robots_for(%URI{host: host} = uri) do
    case Politeness.robots(host) do
      {:ok, robots} ->
        {:ok, robots}

      :miss ->
        url = URI.to_string(%{uri | path: "/robots.txt", query: nil, fragment: nil})

        robots =
          case get(url, robots: true) do
            {:ok, %{status: 200, body: body}} when is_binary(body) -> Robots.parse(body)
            _ -> nil
          end

        Politeness.put_robots(host, robots)
        {:ok, robots}
    end
  end

  defp get(url, opts \\ []) do
    case Req.get(url,
           headers: [{"user-agent", @user_agent}, {"accept", accept(opts)}],
           receive_timeout: @timeout_ms,
           max_redirects: @max_redirects,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{} = response} -> shape(response, url, opts)
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp accept(robots: true), do: "text/plain,*/*"
  defp accept(_opts), do: "text/html,application/xhtml+xml"

  defp shape(%Req.Response{status: status, body: body, headers: headers}, url, opts) do
    type = headers |> header("content-type") |> to_string() |> String.downcase()
    length = headers |> header("content-length") |> parse_int()

    cond do
      status >= 400 ->
        {:error, {:http, status}}

      is_integer(length) and length > @max_bytes ->
        {:error, {:too_large, length}}

      not robots?(opts) and type != "" and not html?(type) ->
        {:error, {:not_html, type}}

      true ->
        {:ok, %{status: status, body: truncate(body), content_type: type, url: url}}
    end
  end

  defp robots?(opts), do: Keyword.get(opts, :robots, false)

  defp html?(type), do: String.contains?(type, "html") or String.starts_with?(type, "text/")

  defp truncate(body) when is_binary(body) and byte_size(body) > @max_bytes,
    do: binary_part(body, 0, @max_bytes)

  defp truncate(body) when is_binary(body), do: body
  defp truncate(_body), do: ""

  defp header(headers, name) when is_map(headers) do
    headers |> Map.get(name, []) |> List.first()
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> nil
    end
  end
end
