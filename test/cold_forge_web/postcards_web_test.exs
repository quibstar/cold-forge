defmodule ColdForgeWeb.PostcardsWebTest do
  @moduledoc """
  The ends of a mailed postcard — the scan from a stranger's phone, the cards
  you print, the mailing list — and the page that manages them.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.{Flyers, Postcards, Repo}
  alias ColdForge.Sourcing.{Org, Source}

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")

    {:ok, project} =
      Flyers.update_content(project, %{
        "url" => "https://exteriorpro.io/pro",
        "headline" => "Run the job.\nNot the paperwork.",
        "highlights" => "Offline mobile app\nSuper easy to use",
        "terms" => "Free for 30 days. No credit card."
      })

    {:ok, project} =
      ColdForge.Outreach.update_project(project, %{
        postal_address: "Affordable Startup LLC, 4370 Chicago Dr. SW #547, Grandville, MI 49418"
      })

    source =
      Repo.insert!(%Source{
        name: "Roofers",
        project_id: project.id,
        provider: "places",
        segments: ["roofing contractor"],
        localities: ["Michigan"]
      })

    prospect =
      prospect_fixture(project, %{
        company: "Herbert Roofing",
        email: nil,
        phone: "616-555-0100",
        industry: "roofing"
      })

    Repo.insert!(%Org{
      source_id: source.id,
      provider: "places",
      source_ref: "ref-1",
      segment: "roofing contractor",
      name: "Herbert Roofing",
      street: "12 Main St",
      city: "Grand Rapids",
      region: "MI",
      postal_code: "49503",
      prospect_id: prospect.id
    })

    %{conn: conn, project: project}
  end

  defp add_all(project) do
    Postcards.add_cards(project, Postcards.candidates(project.id))
    hd(Postcards.list_postcards(project.id))
  end

  test "a scan is counted and sent on, with no login", %{project: project} do
    card = add_all(project)
    conn = get(build_conn(), ~p"/m/#{card.code}")

    assert redirected_to(conn, 302) =~ "https://exteriorpro.io/pro?s=#{card.code}"
    assert Repo.reload(card).scans_count == 1
    assert build_conn() |> get(~p"/m/nope") |> response(404) =~ "isn't active"
  end

  test "printing is a front and an addressed back per card", %{conn: conn, project: project} do
    card = add_all(project)

    html =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/admin/p/#{project.id}/postcards/print?#{[ids: card.id]}")
      |> html_response(200)

    assert html =~ "1 postcard ready"
    assert html =~ ~s(id="front-#{card.code}")
    assert html =~ ~s(id="back-#{card.code}")
    assert length(Regex.scan(~r/<svg class="qr"/, html)) == 1
    assert html =~ "Grand Rapids, MI 49503"
    assert html =~ "For the crew at Herbert Roofing"
    assert html =~ "4370 Chicago Dr. SW #547"
    assert html =~ "Offline mobile app"
    refute html =~ "admin-drawer"
  end

  test "the front alone, once", %{conn: conn, project: project} do
    card = add_all(project)

    html =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/admin/p/#{project.id}/postcards/print?#{[ids: card.id, side: "front"]}")
      |> html_response(200)

    assert html =~ ~s(id="front-#{card.code}")
    refute html =~ ~s(id="back-#{card.code}")
  end

  test "the mailing list downloads as CSV", %{conn: conn, project: project} do
    card = add_all(project)

    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/admin/p/#{project.id}/postcards/export?#{[ids: card.id]}")

    assert response_content_type(conn, :csv)
    assert response(conn, 200) =~ "Herbert Roofing,12 Main St,Grand Rapids,MI,49503"
  end

  test "printing needs a login", %{conn: conn, project: project} do
    assert redirected_to(get(conn, ~p"/admin/p/#{project.id}/postcards/print")) ==
             ~p"/users/log-in"
  end

  describe "the Postcards tab" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "adds cards for the matching prospects, then prints the ticked ones", %{
      conn: conn,
      project: project
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/postcards")

      assert has_element?(live, "#match-count", "1")
      live |> element("#add-cards") |> render_click()

      [card] = Postcards.list_postcards(project.id)
      assert has_element?(live, "#card-#{card.id}", "Herbert Roofing")
      refute has_element?(live, "#print-cards")

      live |> element("#card-#{card.id} input[type=checkbox]") |> render_click()
      assert has_element?(live, "#print-cards[href*='#{card.id}']")
      assert has_element?(live, "#export-cards[href*='#{card.id}']")

      live |> element("#mark-mailed") |> render_click()
      assert Repo.reload(card).status == "mailed"
    end

    test "narrows who matches", %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/postcards")

      live |> form("#card-filters", filters: %{city: "Detroit"}) |> render_change()
      assert has_element?(live, "#match-count", "0")
    end

    test "saves the note for the back", %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/postcards")

      live
      |> form("#note-form", postcard: %{postcard_note: "Hi {{company}}"})
      |> render_submit()

      assert Flyers.content(Repo.reload(project)).postcard_note == "Hi {{company}}"
    end
  end
end
