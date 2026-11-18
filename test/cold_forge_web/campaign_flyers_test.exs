defmodule ColdForgeWeb.CampaignFlyersTest do
  @moduledoc """
  A campaign's own flyer and postcard: it says the project's words until it's
  edited, then its own, without touching the project's or another campaign's.
  Its places and cards print with its words and scan to its landing page.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.{Flyers, Markets, Postcards, Repo}
  alias ColdForge.Postcards.Postcard

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")

    {:ok, project} =
      Flyers.update_content(project, %{
        "url" => "https://exteriorpro.io/pro",
        "headline" => "Run the job.\nNot the paperwork.",
        "postcard_note" => "Hi {{company}}"
      })

    {:ok, texas} = Markets.create_market(%{project_id: project.id, name: "Texas"})

    %{
      conn: log_in_user(conn, user_fixture()),
      project: project,
      texas: texas,
      base: "/admin/p/#{project.id}/c/#{texas.id}"
    }
  end

  defp texas_wording(ctx, attrs) do
    {:ok, texas} = Flyers.update_content(Repo.reload(ctx.texas), ctx.project, attrs)
    texas
  end

  test "a campaign uses the project's words until it has its own", ctx do
    assert Flyers.content(ctx.project, ctx.texas).headline == "Run the job.\nNot the paperwork."
    refute Flyers.own_content?(ctx.texas)

    texas = texas_wording(ctx, %{"headline" => "Built for Texas roofers"})
    content = Flyers.content(ctx.project, texas)

    # The first save starts from the project's words, so only the headline moved.
    assert content.headline == "Built for Texas roofers"
    assert content.url == "https://exteriorpro.io/pro"
    assert content.postcard_note == "Hi {{company}}"
    assert Flyers.content(Repo.reload(ctx.project)).headline == "Run the job.\nNot the paperwork."

    {:ok, texas} = Flyers.reset_content(texas)
    assert Flyers.content(ctx.project, texas).headline == "Run the job.\nNot the paperwork."
  end

  test "saving on a campaign's Flyers tab changes only that campaign", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/flyers")
    assert view |> element("#wording-source") |> render() =~ "Using ExteriorPro"

    view |> form("#flyer-form", flyer: %{headline: "Texas-sized jobs"}) |> render_submit()

    assert Flyers.content(ctx.project, Repo.reload(ctx.texas)).headline == "Texas-sized jobs"
    assert Flyers.content(Repo.reload(ctx.project)).headline =~ "Run the job."
    assert has_element?(view, "#reset-wording")

    view |> element("#reset-wording") |> render_click()
    refute Flyers.own_content?(Repo.reload(ctx.texas))
  end

  test "a place added in a campaign is its own, prints its words and scans to its page", ctx do
    texas = texas_wording(ctx, %{"url" => "https://exteriorpro.io/texas", "headline" => "Howdy"})

    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/flyers")

    view
    |> form("#new-place-form", place: %{venue_name: "ABC Supply", address: "Austin, TX"})
    |> render_submit()

    [place] = Flyers.list_placements(ctx.project.id, market_id: texas.id)
    assert Flyers.list_placements(ctx.project.id, market_id: nil) == []

    html =
      ctx.conn
      |> get(~p"/admin/p/#{ctx.project.id}/flyers/print?#{[ids: place.id, market_id: texas.id]}")
      |> html_response(200)

    assert html =~ "Howdy"

    conn = get(build_conn(), ~p"/f/#{place.code}")
    assert redirected_to(conn, 302) == "https://exteriorpro.io/texas?s=#{place.code}"
  end

  test "a postcard added in a campaign scans to the campaign's page", ctx do
    texas = texas_wording(ctx, %{"url" => "https://exteriorpro.io/texas"})
    prospect = prospect_fixture(ctx.project, company: "Lone Star Roofing")

    org = %ColdForge.Sourcing.Org{
      name: "Lone Star Roofing",
      street: "1 Main St",
      city: "Austin",
      region: "TX",
      postal_code: "78701"
    }

    assert 1 == Postcards.add_cards(ctx.project, [{prospect, org}], texas.id)
    card = Repo.get_by!(Postcard, prospect_id: prospect.id)
    assert card.market_id == texas.id

    conn = get(build_conn(), ~p"/m/#{card.code}")
    assert redirected_to(conn, 302) =~ "https://exteriorpro.io/texas?"
  end

  test "the card's note saved in a campaign is the campaign's", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.base <> "/postcards")

    view
    |> form("#note-form", postcard: %{postcard_note: "Howdy {{company}}"})
    |> render_submit()

    assert Flyers.content(ctx.project, Repo.reload(ctx.texas)).postcard_note ==
             "Howdy {{company}}"

    assert Flyers.content(Repo.reload(ctx.project)).postcard_note == "Hi {{company}}"
  end

  test "another project's campaign can't be printed under this one", ctx do
    other = project_fixture(name: "Furizzma")
    {:ok, theirs} = Markets.create_market(%{project_id: other.id, name: "Texas"})

    assert_raise Ecto.NoResultsError, fn ->
      get(
        ctx.conn,
        ~p"/admin/p/#{ctx.project.id}/flyers/print?#{[mode: "shop", market_id: theirs.id]}"
      )
    end
  end
end
