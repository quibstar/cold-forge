defmodule ColdForge.Workers.RunPermitSources do
  @moduledoc """
  Weekly: runs every active permit source, so new contractors are found without
  anyone pressing Run. Monday morning, so the website lookups and crawls are
  done by the digest on Tuesday (`ColdForge.Workers.PermitDigest`).

  Finding is all this does. Nobody is added or emailed until someone looks at
  the results and clicks Add all.
  """
  use Oban.Worker, queue: :search, max_attempts: 1

  require Logger

  alias ColdForge.Sourcing

  @impl Oban.Worker
  def perform(_job) do
    sources = Enum.filter(Sourcing.list_sources(), &(&1.active and &1.provider == "permits"))

    for source <- sources do
      case Sourcing.run_source(source) do
        {:ok, _} ->
          Logger.info("permits: started #{source.name}")

        {:error, reason} ->
          Logger.error("permits: #{source.name} didn't start: #{inspect(reason)}")
      end
    end

    :ok
  end
end
