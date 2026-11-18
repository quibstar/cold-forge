defmodule ColdForgeWeb.MarketsLiveTest do
  @moduledoc """
  The campaign screens: making one, its tabs, and that the working screens
  inside it show only its people and keep you inside it as you click around.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.{Markets, Outreach, Repo, Sourcing}
  alias ColdForge.Sourcing.{Org, Source}

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")
    {:ok, market} = Markets.create_market(%{project_id: project.id, name: "Grand Rapids"})

    source =
      Repo.insert!(%Source{
        name: "GR roofers",
        project_id: project.id,
        market_id: market.id,
        provider: "places",
        segments: ["roofing"],
        localities: ["Grand Rapids, MI"]
      })

    inside = prospect_fixture(project, company: "Herbert Roofing", phone: "616-555-0100")

    Repo.insert!(%Org{
      source_id: source.id,
      provider: "places",
      source_ref: "ref-1",
      segment: "roofing",
      name: inside.company,
      prospect_id: inside.id
    })

    outside = prospect_fixture(project, company: "Lone Star Siding", phone: "214-555-0100")
    sequence = campaign_fixture(project, %{market_id: market.id, name: "GR drip"})
    step = step_fixture(sequence)

    %{
      conn: log_in_user(conn, user_fixture()),
      project: project,
      market: market,
      source: source,
      inside: inside,
      outside: outside,
      sequence: sequence,
      step: step,
      base: "/admin/p/#{project.id}/c/#{market.id}"
    }
  end

  test "a project's front page lists its campaigns", ctx do
    {:ok, _view, html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}")

    assert html =~ "Grand Rapids"
    assert html =~ ~s|href="#{ctx.base}"|
  end

  test "creating a campaign opens it", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/c/new")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> form("#market-form", market: %{name: "Texas"}) |> render_submit()

    [texas] = ctx.project.id |> Markets.list_markets() |> Enum.filter(&(&1.name == "Texas"))
    assert to == "/admin/p/#{ctx.project.id}/c/#{texas.id}"
  end

  test "every screen inside a campaign renders, under the campaign's tabs", ctx do
    paths = [
      ctx.base,
      ctx.base <> "/edit",
      ctx.base <> "/sourcing",
      ctx.base <> "/sourcing/new",
      ctx.base <> "/sourcing/#{ctx.source.id}",
      ctx.base <> "/sourcing/#{ctx.source.id}/edit",
      ctx.base <> "/prospects",
      ctx.base <> "/prospects/#{ctx.inside.id}/edit",
      ctx.base <> "/campaigns",
      ctx.base <> "/campaigns/new",
      ctx.base <> "/campaigns/#{ctx.sequence.id}",
      ctx.base <> "/campaigns/#{ctx.sequence.id}/people",
      ctx.base <> "/campaigns/#{ctx.sequence.id}/emails/#{ctx.step.id}",
      ctx.base <> "/calls",
      ctx.base <> "/calls/#{ctx.inside.id}",
      ctx.base <> "/postcards",
      ctx.base <> "/flyers",
      ctx.base <> "/replies",
      ctx.base <> "/activity"
    ]

    for path <- paths do
      assert {:ok, _view, html} = live(ctx.conn, path), "#{path} failed to render"

      # Forms and detail pages carry a breadcrumb instead of the tab row.
      if not String.ends_with?(path, ["/edit", "/new", "/people"]) and
           not String.contains?(path, "/emails/") do
        assert html =~ ~s|href="#{ctx.base}/calls"|, "#{path} is missing the campaign's tabs"
      end
    end
  end

  test "the overview counts the campaign and links to its search and sequence", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.base)

    assert view |> element("#market-sources") |> render() =~ "GR roofers"
    assert view |> element("#market-sequences") |> render() =~ "GR drip"
    assert has_element?(view, ~s|#market-sources a[href="#{ctx.base}/sourcing/#{ctx.source.id}"]|)
  end

  test "people and calls show only the campaign's people, and links stay inside it", ctx do
    {:ok, _view, html} = live(ctx.conn, ctx.base <> "/prospects")
    assert html =~ "Herbert Roofing"
    refute html =~ "Lone Star Siding"

    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/calls")

    assert has_element?(
             view,
             ~s|#queue-#{ctx.inside.id}[href="#{ctx.base}/calls/#{ctx.inside.id}"]|
           )

    refute has_element?(view, "#queue-#{ctx.outside.id}")

    # The project's own list still has everyone.
    {:ok, _view, html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")
    assert html =~ "Lone Star Siding"
  end

  test "a search or sequence made inside a campaign belongs to it", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/campaigns/new")
    view |> form("#campaign-form", campaign: %{name: "GR follow-up"}) |> render_submit()

    assert [%{market_id: market_id}] =
             ctx.project.id
             |> Outreach.list_campaigns()
             |> Enum.filter(&(&1.name == "GR follow-up"))

    assert market_id == ctx.market.id

    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/sourcing/new")

    view
    |> form("#source-form",
      source: %{name: "GR siding", segments_text: "siding", localities_text: "Grand Rapids, MI"}
    )
    |> render_submit()

    assert [%{market_id: ^market_id}] =
             Sourcing.list_sources(project_id: ctx.project.id)
             |> Enum.filter(&(&1.name == "GR siding"))
  end

  test "a loose sequence moves into a campaign from the project page", ctx do
    loose = campaign_fixture(ctx.project, %{name: "Old blast"})
    {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}")

    assert view |> element("#unassigned") |> render() =~ "Old blast"

    view
    |> form("#move-campaign-#{loose.id}", %{market_id: ctx.market.id})
    |> render_change()

    assert Repo.reload(loose).market_id == ctx.market.id
    refute has_element?(view, "#unassigned")
  end

  test "renaming and deleting", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/edit")

    view |> form("#market-form", market: %{name: "GR + suburbs"}) |> render_submit()
    assert Repo.reload(ctx.market).name == "GR + suburbs"

    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/edit")
    view |> element("#delete-market") |> render_click()

    assert Repo.get(ColdForge.Markets.Market, ctx.market.id) == nil
    assert Repo.reload(ctx.sequence).market_id == nil
  end

  test "another project's campaign can't be opened under this one", ctx do
    other = project_fixture(name: "Furizzma")
    {:ok, theirs} = Markets.create_market(%{project_id: other.id, name: "Texas"})

    assert_raise Ecto.NoResultsError, fn ->
      live(ctx.conn, "/admin/p/#{ctx.project.id}/c/#{theirs.id}/prospects")
    end
  end
end
