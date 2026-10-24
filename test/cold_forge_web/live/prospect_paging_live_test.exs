defmodule ColdForgeWeb.AdminLive.ProspectPagingTest do
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup %{conn: conn} do
    project = project_fixture(name: "Paging")

    for i <- 1..(Outreach.per_page() + 10) do
      prospect_fixture(project, company: "Co #{String.pad_leading("#{i}", 3, "0")}")
    end

    %{conn: log_in_user(conn, user_fixture()), project: project}
  end

  test "shows the first page and how many there are", %{conn: conn, project: project} do
    {:ok, _live, html} = live(conn, ~p"/admin/p/#{project.id}/prospects")

    assert html =~ "1–50 of 60"
    assert html =~ ~s(aria-current="page" aria-label="Page 1")
  end

  test "Next moves to the second page", %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects")

    html = live |> element(~s(button[phx-click="page"][phx-value-to="next"])) |> render_click()

    assert html =~ "51–60 of 60"
    assert html =~ ~s(aria-current="page" aria-label="Page 2")
  end

  test "Previous comes back", %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects")

    live |> element(~s(button[phx-value-to="next"])) |> render_click()
    html = live |> element(~s(button[phx-value-to="prev"])) |> render_click()

    assert html =~ ~s(aria-current="page" aria-label="Page 1")
  end

  test "filtering returns to page 1 rather than an empty page 2",
       %{conn: conn, project: project} do
    {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/prospects")

    live |> element(~s(button[phx-value-to="next"])) |> render_click()

    html =
      live
      |> form(~s(form[phx-change="filter"]), %{search: "Co 001", status: "all"})
      |> render_change()

    assert html =~ "Co 001"
    refute html =~ ~s(aria-label="Page 2")
  end

  test "no pager at all when everything fits on one page", %{conn: conn} do
    small = project_fixture(name: "Small")
    prospect_fixture(small, company: "Only One")

    {:ok, _live, html} = live(conn, ~p"/admin/p/#{small.id}/prospects")

    assert html =~ "Only One"
    # No pager at all, so not even the arrows.
    refute html =~ ~s(aria-label="Next page")
  end
end
