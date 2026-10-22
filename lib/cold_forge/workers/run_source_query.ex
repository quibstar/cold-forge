defmodule ColdForge.Workers.RunSourceQuery do
  @moduledoc """
  One segment in one town, through the source's provider, then straight into
  the crawl queue.

  Pages to the end of the provider's results before stopping — Places caps a
  text search at sixty, which is why a source is many narrow queries rather
  than one broad one.

  Discovered rows carry their `source_id`, so a search's results stay its own
  and the project they belong to is already decided.
  """

  use Oban.Worker, queue: :crawl, max_attempts: 3

  require Logger

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Discovery.{Overpass, Places}

  # Enough to exhaust a provider's paging without looping forever if one
  # always hands back a token.
  @max_pages 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "segment" => segment} = args}) do
    source = Sourcing.get_source!(source_id)
    locality = Map.get(args, "locality")

    with {:ok, rows} <- discover(source.provider, segment, locality),
         rows = Enum.map(rows, &Map.put(&1, :source_id, source.id)),
         {:ok, counts} <- Sourcing.record_discovered(rows) do
      queued =
        Sourcing.crawlable(source_id: source.id, segment: segment, limit: 200)
        |> Sourcing.enqueue_crawls()

      Logger.info(
        "sourcing: #{source.name} / #{segment} / #{locality} — " <>
          "#{counts.inserted} new, #{counts.skipped} already known, #{queued} queued to crawl"
      )

      :ok
    else
      {:error, :no_api_key} ->
        # Nothing to retry: the key is missing, not flaky.
        Logger.error("sourcing: #{source.name} has no provider key configured")
        {:cancel, :no_api_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discover("places", segment, locality), do: places_pages(segment, locality, nil, [], 1)

  defp discover("overpass", segment, iso_region) do
    query = Overpass.query([segment], iso_region)

    case Req.post(Overpass.endpoint(),
           form: [data: query],
           headers: [{"user-agent", ColdForge.Sourcing.Fetcher.user_agent()}],
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> Overpass.parse(body, segment)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp discover(provider, _segment, _locality), do: {:error, {:unsupported_provider, provider}}

  defp places_pages(_segment, _locality, _token, acc, page) when page > @max_pages,
    do: {:ok, acc}

  defp places_pages(segment, locality, token, acc, page) do
    opts = if token, do: [page_token: token], else: []

    case Places.search(segment, locality, opts) do
      {:ok, rows, nil} -> {:ok, acc ++ rows}
      {:ok, rows, next} -> places_pages(segment, locality, next, acc ++ rows, page + 1)
      {:error, reason} -> if acc == [], do: {:error, reason}, else: {:ok, acc}
    end
  end
end
