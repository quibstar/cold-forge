defmodule ColdForgeWeb.FlyersWebTest do
  @moduledoc """
  The two ends of a printed flyer — the scan from a stranger's phone, and the
  sheet you print — plus the page that manages them.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.{Flyers, Repo}

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")

    {:ok, project} =
      Flyers.update_content(project, %{
        "url" => "https://exteriorpro.io/pro",
        "headline" => "Run the job.\nNot the paperwork.",
        "terms" => "Free for 30 days. No credit card."
      })

    {:ok, placement} =
      Flyers.create_placement(project, %{venue_name: "ABC Supply", address: "Wyoming, MI"})

    %{conn: conn, project: project, placement: placement}
  end

  describe "a scan" do
    test "is counted, then sent on to the landing page", %{conn: conn, placement: placement} do
      conn = get(conn, ~p"/f/#{placement.code}")

      assert redirected_to(conn, 302) == "https://exteriorpro.io/pro?s=#{placement.code}"
      assert Repo.reload(placement).scans_count == 1
    end

    test "needs no login — it's a stranger's phone", %{placement: placement} do
      conn = get(build_conn(), ~p"/f/#{placement.code}")
      assert redirected_to(conn, 302) =~ "exteriorpro.io"
    end

    test "of an unknown code is a 404", %{conn: conn} do
      assert conn |> get(~p"/f/nope") |> response(404) =~ "isn't active"
    end
  end

  describe "printing" do
    test "is a Letter sheet per place, each with its own QR", %{
      conn: conn,
      project: project,
      placement: placement
    } do
      {:ok, other} =
        Flyers.create_placement(project, %{venue_name: "Beacon", address: "Holland, MI"})

      html =
        conn
        |> log_in_user(user_fixture())
        |> get(~p"/admin/p/#{project.id}/flyers/print?#{[ids: "#{placement.id},#{other.id}"]}")
        |> html_response(200)

      assert html =~ "2 flyers ready"
      assert html =~ ~s(id="flyer-#{placement.code}")
      assert html =~ ~s(id="flyer-#{other.code}")
      assert length(Regex.scan(~r/<svg class="qr"/, html)) == 2
      assert html =~ "Run the job.<br/>Not the paperwork." or html =~ "Not the paperwork."
      assert html =~ "exteriorpro.io/pro"
      # Standalone: none of the admin chrome.
      refute html =~ "admin-drawer"
    end

    test "needs a login", %{conn: conn, project: project} do
      conn = get(conn, ~p"/admin/p/#{project.id}/flyers/print")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "the Flyers tab" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "lists places with their scans and a print link once ticked", %{
      conn: conn,
      project: project,
      placement: placement
    } do
      {:ok, _} = Flyers.record_scan(placement.code)
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/flyers")

      assert has_element?(live, "#placement-#{placement.id}", "ABC Supply")
      refute has_element?(live, "#print-flyers")

      live |> element("#placement-#{placement.id} input[type=checkbox]") |> render_click()
      assert has_element?(live, "#print-flyers[href*='#{placement.id}']")
    end

    test "adds a place by hand", %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/flyers")

      live
      |> form("#new-place-form",
        place: %{venue_name: "SRS Distribution", address: "Grandville, MI"}
      )
      |> render_submit()

      assert Enum.any?(
               Flyers.list_placements(project.id),
               &(&1.code == "srs-distribution-grandville")
             )
    end

    test "changes a place's status from the list", %{
      conn: conn,
      project: project,
      placement: placement
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/flyers")

      live
      |> form("#status-#{placement.id}", %{placement_id: placement.id, status: "posted"})
      |> render_change()

      assert Repo.reload(placement).status == "posted"
    end

    test "saves what the flyer says", %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/flyers")

      live
      |> form("#flyer-form", flyer: %{footer: "ExteriorPro — built by a contractor."})
      |> render_submit()

      assert Flyers.content(Repo.reload(project)).footer == "ExteriorPro — built by a contractor."
    end

    test "won't delete a place that's been scanned", %{
      conn: conn,
      project: project,
      placement: placement
    } do
      {:ok, _} = Flyers.record_scan(placement.code)
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/flyers/#{placement.id}/edit")

      refute has_element?(live, "button[phx-click='delete_place']")
    end
  end
end
