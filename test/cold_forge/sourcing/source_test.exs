defmodule ColdForge.Sourcing.SourceTest do
  @moduledoc """
  What a saved search accepts and what it will run.

  Google Places takes any wording, so a search takes any trade; OpenStreetMap
  can only search the tags it has. A state becomes its towns, and the plan
  shows the request count and rough cost before anything runs.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Source, Towns}
  alias ColdForge.Workers.{RunSource, RunSourceQuery}

  setup do
    %{project: project_fixture()}
  end

  defp changeset(project, attrs) do
    Sourcing.change_source(
      %Source{},
      Map.merge(%{"name" => "Test", "project_id" => project.id, "provider" => "places"}, attrs)
    )
  end

  test "takes exactly what was typed in the field that failed before", ctx do
    cs =
      changeset(ctx.project, %{
        "segments_text" => ~s(Roofing, Siding, "Window & Doors" ,),
        "localities_text" => "Grand Rapids, MI"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :segments) == ["roofing", "siding", "windows"]
  end

  test "Places takes a trade it has no tuned phrases for", ctx do
    cs =
      changeset(ctx.project, %{
        "segments_text" => "Deck builder | deck contractor, fencing",
        "localities_text" => "Holland, MI"
      })

    assert cs.valid?

    assert Ecto.Changeset.get_field(cs, :segments) ==
             ["deck builder | deck contractor", "fencing"]
  end

  test "OpenStreetMap still only takes what it has tags for", ctx do
    cs =
      changeset(ctx.project, %{
        "provider" => "overpass",
        "segments_text" => "deck builder",
        "localities_text" => "US-MI"
      })

    refute cs.valid?
    assert errors_on(cs).segments_text |> hd() =~ "can't search for"
  end

  test "a two-letter code that isn't a state is caught before it costs anything", ctx do
    cs =
      changeset(ctx.project, %{"segments_text" => "roofing", "localities_text" => "Michigan\nMX"})

    refute cs.valid?
    assert "MX isn't a state" in errors_on(cs).localities_text
  end

  describe "queries/1 and plan/1" do
    test "a state becomes one search per phrase per town" do
      source = %Source{provider: "places", segments: ["roofing"], localities: ["Michigan"]}
      towns = Towns.towns("MI")

      # roofing has two tuned phrases, and now both run.
      assert length(Source.queries(source)) == 2 * length(towns)
      assert {"roofing", "roofer", "Grand Rapids, MI"} in Source.queries(source)

      plan = Source.plan(source)
      assert plan.towns == length(towns)
      assert plan.states == [{"Michigan", length(towns)}]
      assert plan.searches == 2 * length(towns)
      assert plan.max_requests == 3 * plan.searches
      assert plan.min_cost > 0
      assert plan.max_cost > plan.min_cost
    end

    test "a town listed twice, or inside a state also listed, is searched once" do
      source = %Source{
        provider: "places",
        segments: ["fencing"],
        localities: ["Michigan", "Grand Rapids, MI", "Grand Rapids, MI"]
      }

      assert Source.plan(source).towns == length(Towns.towns("MI"))
    end

    test "nothing typed yet is nothing to run" do
      assert Source.plan(%Source{provider: "places", segments: [], localities: []}).searches == 0
    end
  end

  test "running queues a job per phrase per town, carrying the phrase", ctx do
    {:ok, source} =
      Sourcing.create_source(%{
        "name" => "Windows in two towns",
        "project_id" => ctx.project.id,
        "provider" => "places",
        "segments_text" => "Windows & Doors",
        "localities_text" => "Holland, MI\nZeeland, MI"
      })

    assert :ok = perform_job(RunSource, %{source_id: source.id})

    jobs = all_enqueued(worker: RunSourceQuery)
    assert length(jobs) == 4

    assert_enqueued(
      worker: RunSourceQuery,
      args: %{
        source_id: source.id,
        segment: "windows",
        query: "window and door contractor",
        locality: "Zeeland, MI"
      }
    )
  end
end
