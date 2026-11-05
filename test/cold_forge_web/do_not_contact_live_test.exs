defmodule ColdForgeWeb.DoNotContactLiveTest do
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")
    %{conn: log_in_user(conn, user_fixture()), project: project}
  end

  test "the Prospects tab links to the list", %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects")
    assert has_element?(live, "#do-not-contact-link")
  end

  test "adds a company, stopping the prospect on file", %{conn: conn, project: project} do
    prospect_fixture(project, %{company: "Cochran Exteriors", email: "c@cochran.com"})
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects/do-not-contact")

    live
    |> form("#dnc-form", entry: %{name: "Cochran Exteriors", domain: "https://www.cochran.com/"})
    |> render_submit()

    assert has_element?(live, "#dnc-entries", "Cochran Exteriors")
    assert has_element?(live, "#dnc-entries", "cochran.com")
    assert has_element?(live, "#dnc-caught", "Cochran Exteriors")
    assert Outreach.suppressed?("c@cochran.com")
  end

  test "takes a company off the list", %{conn: conn, project: project} do
    {:ok, {entry, 0}} = ColdForge.DoNotContact.add(project.id, %{"name" => "Couto Construction"})
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects/do-not-contact")

    live |> element("#dnc-#{entry.id} button") |> render_click()
    refute has_element?(live, "#dnc-#{entry.id}")
  end
end
