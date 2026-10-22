defmodule ColdForge.Sourcing.CrawlQueueTest do
  @moduledoc """
  The website-check queue. A Michigan run built 105,875 queued checks for
  about 1,600 websites — every finished search re-queued the oldest 200 not
  yet checked — while 963 newer ones were never queued at all, so the run
  could never finish. These pin the fixes.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Repo, Sourcing}
  alias ColdForge.Sourcing.{Org, Source}
  alias ColdForge.Workers.CrawlOrg

  setup do
    project = project_fixture()

    source =
      Repo.insert!(%Source{
        name: "Michigan #{System.unique_integer([:positive])}",
        project_id: project.id,
        provider: "places",
        segments: ["roofing"],
        localities: ["Holland, MI"]
      })

    %{source: source}
  end

  defp org(source, attrs \\ %{}) do
    %Org{}
    |> Org.discovery_changeset(
      Map.merge(
        %{
          name: "Summit Roofing",
          segment: "roofing",
          provider: "places",
          source_ref: "ref-#{System.unique_integer([:positive])}",
          source_id: source.id,
          website: "https://summit.test"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # Bypasses the worker's uniqueness, the way the old code effectively did.
  defp raw_job(org) do
    %{org_id: org.id}
    |> Oban.Job.new(worker: CrawlOrg, queue: :crawl)
    |> Repo.insert!()
  end

  defp crawl_jobs, do: all_enqueued(worker: CrawlOrg)

  test "a place is never queued for a check twice", %{source: source} do
    o = org(source)

    assert Sourcing.enqueue_crawls([o]) == 1
    Sourcing.enqueue_crawls([o])

    assert length(crawl_jobs()) == 1
  end

  test "record_discovered hands back what it inserted, so only those get queued", %{
    source: source
  } do
    attrs = %{
      name: "New Co",
      segment: "roofing",
      provider: "places",
      source_ref: "x1",
      source_id: source.id
    }

    {:ok, %{inserted: 1, skipped: 1, orgs: [inserted]}} =
      Sourcing.record_discovered([attrs, attrs])

    assert inserted.name == "New Co"
  end

  test "queue_missing_crawls queues every waiting website, however new", %{source: source} do
    queued = org(source)
    Sourcing.enqueue_crawls([queued])

    missed = for _ <- 1..3, do: org(source)
    no_site = org(source, %{website: nil})

    assert Sourcing.progress(Repo.reload(source)).stalled == 3
    assert Sourcing.queue_missing_crawls(source) == 3

    ids = Enum.map(crawl_jobs(), & &1.args["org_id"]) |> Enum.sort()
    assert ids == Enum.sort([queued.id | Enum.map(missed, & &1.id)])
    refute no_site.id in ids
    assert Sourcing.progress(Repo.reload(source)).stalled == 0
  end

  test "clear_redundant_crawls drops copies and checks for settled places", %{source: source} do
    waiting = org(source)
    for _ <- 1..4, do: raw_job(waiting)

    settled = org(source)
    raw_job(settled)
    {:ok, _} = Sourcing.reject(settled, :no_address_published)

    assert length(crawl_jobs()) == 5
    assert Sourcing.clear_redundant_crawls() == 4

    assert [job] = crawl_jobs()
    assert job.args["org_id"] == waiting.id
  end

  test "clicking Run twice queues one run, not two", %{source: source} do
    {:ok, _} = Sourcing.run_source(source)
    {:ok, _} = Sourcing.run_source(source)

    assert length(all_enqueued(worker: ColdForge.Workers.RunSource)) == 1
    assert Sourcing.progress(source).waiting_to_start
    refute Sourcing.progress(source).done
  end

  test "the same search in the same town is queued once", %{source: source} do
    args = %{source_id: source.id, segment: "roofing", query: "roofer", locality: "Holland, MI"}

    args |> ColdForge.Workers.RunSourceQuery.new() |> Oban.insert!()
    args |> ColdForge.Workers.RunSourceQuery.new() |> Oban.insert!()

    assert length(all_enqueued(worker: ColdForge.Workers.RunSourceQuery)) == 1
  end

  test "searches run on their own queue, not behind website checks", %{source: source} do
    {:ok, _} = Sourcing.run_source(source)
    assert [%{queue: "search"}] = all_enqueued(worker: ColdForge.Workers.RunSource)
  end

  describe "progress/1" do
    test "isn't done before it has ever run", %{source: source} do
      refute Sourcing.progress(source).done
    end

    test "counts searches left against the run's total, and websites left", %{source: source} do
      {:ok, source} = Sourcing.touch_run(source, %{"queries" => 3})

      for town <- ["Holland, MI", "Zeeland, MI"] do
        %{source_id: source.id, segment: "roofing", query: "roofer", locality: town}
        |> ColdForge.Workers.RunSourceQuery.new()
        |> Oban.insert!()
      end

      o = org(source)
      Sourcing.enqueue_crawls([o])

      progress = Sourcing.progress(source)
      assert progress.searches_total == 3
      assert progress.searches_left == 2
      assert progress.searches_done == 1
      assert progress.checking == 1
      assert progress.stalled == 0
      refute progress.done
    end

    test "is done once nothing is left to search or check", %{source: source} do
      {:ok, source} = Sourcing.touch_run(source, %{"queries" => 1})
      o = org(source)
      {:ok, _} = Sourcing.reject(o, :no_address_published)

      assert Sourcing.progress(source).done
    end
  end
end
