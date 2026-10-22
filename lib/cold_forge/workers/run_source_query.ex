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

  # One copy of each search at a time, whatever queued it.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [
      keys: [:source_id, :segment, :query, :locality],
      states: :incomplete,
      period: :infinity
    ]

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
    # Jobs queued before phrases ran separately carry no "query"; they search
    # the segment's first phrase, as they always did.
    phrase = Map.get(args, "query")

    with {:ok, rows} <- discover(source.provider, segment, phrase, locality),
         rows = Enum.map(rows, &Map.put(&1, :source_id, source.id)),
         {:ok, counts} <- Sourcing.record_discovered(rows) do
      # Only what this search just found. Re-queuing "the oldest 200 not yet
      # checked" after every search queued the same places hundreds of times
      # and never reached the newer ones at all.
      # A flyers search wants the place, not an email address from its website.
      queued =
        if ColdForge.Sourcing.Source.flyers?(source),
          do: 0,
          else:
            counts.orgs |> Enum.filter(&(&1.status == "discovered")) |> Sourcing.enqueue_crawls()

      Logger.info(
        "sourcing: #{source.name} / #{phrase || segment} / #{locality} — " <>
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

  defp discover("places", segment, phrase, locality),
    do: places_pages(segment, phrase, locality, nil, [], 1)

  defp discover("overpass", segment, _phrase, iso_region) do
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

  defp discover(provider, _segment, _phrase, _locality),
    do: {:error, {:unsupported_provider, provider}}

  defp places_pages(_segment, _phrase, _locality, _token, acc, page) when page > @max_pages,
    do: {:ok, acc}

  defp places_pages(segment, phrase, locality, token, acc, page) do
    opts = Enum.reject([page_token: token, query: phrase], fn {_k, v} -> is_nil(v) end)

    case Places.search(segment, locality, opts) do
      {:ok, rows, nil} ->
        {:ok, acc ++ rows}

      {:ok, rows, next} ->
        places_pages(segment, phrase, locality, next, acc ++ rows, page + 1)

      {:error, reason} ->
        if acc == [], do: {:error, reason}, else: {:ok, acc}
    end
  end
end
