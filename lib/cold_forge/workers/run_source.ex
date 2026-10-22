defmodule ColdForge.Workers.RunSource do
  @moduledoc """
  Starts a saved search: one job per phrase and town (a state having already
  become its towns in `Source.queries/1`).

  Fans out rather than looping, because a source covering four trades across
  twelve towns is forty-eight provider calls. As one job that is a long,
  all-or-nothing thing that retries from the beginning; as forty-eight it
  retries only the query that failed, and the page can show progress while it
  runs.
  """

  # Its own queue, so it never waits behind website checks. Unique per source
  # while one is waiting or running: clicking Run twice must not run — and pay
  # for — every search twice.
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [keys: [:source_id], states: :incomplete, period: :infinity]

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Source
  alias ColdForge.Workers.RunSourceQuery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Sourcing.get_source!(source_id)
    queries = Source.queries(source)

    queued =
      queries
      |> Enum.map(fn {segment, phrase, locality} ->
        RunSourceQuery.new(%{
          source_id: source.id,
          segment: segment,
          query: phrase,
          locality: locality
        })
      end)
      |> Enum.count(&match?({:ok, _}, Oban.insert(&1)))

    {:ok, _source} =
      Sourcing.touch_run(source, %{
        "queries" => length(queries),
        "queued" => queued,
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    :ok
  end
end
