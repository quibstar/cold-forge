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

  test "prints in the project's own brand", %{conn: conn, project: project} do
    card = add_all(project)
    {:ok, project} = ColdForge.Outreach.update_project(project, %{slug: "furizzma"})

    html =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/admin/p/#{project.id}/postcards/print?#{[ids: card.id]}")
      |> html_response(200)

    assert html =~ "/images/flyers/furizzma-photo.webp"
    assert html =~ "/images/flyers/furizzma-logo.png"
    assert html =~ "For everyone at Herbert Roofing"
    assert html =~ "--band-bg: #EAB308"
    refute html =~ "exteriorpro-avatar"
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

  describe "printing in bulk" do
    setup %{conn: conn, project: project} do
      {:ok, project} =
        Flyers.update_content(project, %{
          "postcard_note" => "A free place for {{company}}.\n\nMore."
        })

      %{conn: log_in_user(conn, user_fixture()), project: project, card: add_all(project)}
    end

    test "the print shop's card is the same for everyone, blanks and all", %{
      conn: conn,
      project: project,
      card: card
    } do
      html =
        conn
        |> get(~p"/admin/p/#{project.id}/postcards/print?#{[mode: "shop"]}")
        |> html_response(200)

      assert html =~ ~s(class="mode-shop")
      assert html =~ "For a print shop."
      # One front and one back, with no recipient on either.
      assert length(Regex.scan(~r/class="side front"/, html)) == 1
      assert length(Regex.scan(~r/class="side back"/, html)) == 1
      refute html =~ ~s(<svg class="qr")
      refute html =~ card.name
      refute html =~ card.street
      # The note's company is made generic: one note is printed for all.
      assert html =~ "A free place for your company."
    end

    test "the overlay is each card's greeting, QR and address, in the same layout", %{
      conn: conn,
      project: project,
      card: card
    } do
      html =
        conn
        |> get(~p"/admin/p/#{project.id}/postcards/print?#{[ids: card.id, mode: "overlay"]}")
        |> html_response(200)

      assert html =~ ~s(class="mode-overlay")
      # Backs only, one per card.
      refute html =~ ~s(class="side front")
      assert length(Regex.scan(~r/class="side back"/, html)) == 1
      assert length(Regex.scan(~r/<svg class="qr"/, html)) == 1
      assert html =~ card.street
      # The same generic note as the shop's card, so the two line up.
      assert html =~ "A free place for your company."
    end

    test "the tab links both passes", %{conn: conn, project: project, card: card} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/postcards")

      assert has_element?(live, "#print-shop-card[href*='mode=shop']")
      live |> element("#card-#{card.id} input[type=checkbox]") |> render_click()
      assert has_element?(live, "#print-overlay[href*='mode=overlay'][href*='#{card.id}']")
    end
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

    test "pages a long list, keeping ticks across pages", %{conn: conn, project: project} do
      for n <- 1..60 do
        Repo.insert!(%ColdForge.Postcards.Postcard{
          project_id: project.id,
          code: "card-#{n}",
          name: "Roofer #{n}",
          street: "#{n} Main St",
          city: "Grand Rapids",
          region: "MI",
          postal_code: "49503"
        })
      end

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/postcards")

      rows = fn ->
        live |> render() |> LazyHTML.from_document() |> LazyHTML.query("#postcards tbody tr")
      end

      assert has_element?(live, "#postcards-pages")
      assert Enum.count(rows.()) == 50

      first = rows.() |> Enum.at(0) |> LazyHTML.attribute("id") |> hd()
      live |> element("##{first} input[type=checkbox]") |> render_click()

      live |> element("#postcards-pages button[aria-label='Page 2']") |> render_click()
      assert Enum.count(rows.()) == 10
      refute has_element?(live, "##{first}")

      live |> element("#tick-page") |> render_click()
      assert has_element?(live, "#print-cards", "Print 11 cards")
    end
  end
end
