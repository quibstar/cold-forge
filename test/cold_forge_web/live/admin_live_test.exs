defmodule ColdForgeWeb.AdminLiveTest do
  @moduledoc """
  Walks every admin screen. A route that 404s or a LiveView that raises on
  mount is invisible until somebody clicks it, which is exactly the failure
  these catch.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")
    sequence = sequence_fixture(project)
    step = step_fixture(sequence)
    prospect = prospect_fixture(project, first_name: "Dana", company: "Northside Siding")

    %{
      conn: log_in_user(conn, user_fixture()),
      project: project,
      sequence: sequence,
      step: step,
      prospect: prospect
    }
  end

  test "the admin requires a signed-in operator" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
  end

  test "dashboard lists projects with their counters", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "ExteriorPro"
    assert html =~ "Dashboard"
  end

  test "every sidebar destination renders", ctx do
    paths = [
      ~p"/admin",
      ~p"/admin/projects",
      ~p"/admin/projects/new",
      ~p"/admin/suppressions",
      ~p"/admin/p/#{ctx.project.id}/prospects",
      ~p"/admin/p/#{ctx.project.id}/prospects/new",
      ~p"/admin/p/#{ctx.project.id}/prospects/#{ctx.prospect.id}/edit",
      ~p"/admin/p/#{ctx.project.id}/sequences",
      ~p"/admin/p/#{ctx.project.id}/sequences/new",
      ~p"/admin/p/#{ctx.project.id}/sequences/#{ctx.sequence.id}",
      ~p"/admin/p/#{ctx.project.id}/sequences/#{ctx.sequence.id}/steps/new",
      ~p"/admin/p/#{ctx.project.id}/sequences/#{ctx.sequence.id}/steps/#{ctx.step.id}",
      ~p"/admin/p/#{ctx.project.id}/sequences/#{ctx.sequence.id}/enroll",
      ~p"/admin/p/#{ctx.project.id}/messages"
    ]

    for path <- paths do
      assert {:ok, _view, _html} = live(ctx.conn, path), "#{path} failed to render"
    end
  end

  test "the per-project nav section only appears once a project is in scope", ctx do
    {:ok, _view, html} = live(ctx.conn, ~p"/admin/projects")
    refute html =~ ~s|href="/admin/p/#{ctx.project.id}/sequences"|

    {:ok, _view, html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")
    assert html =~ ~s|href="/admin/p/#{ctx.project.id}/sequences"|
  end

  describe "search palette" do
    test "finds a prospect from anywhere, not just its own project", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/suppressions")

      html =
        view
        |> element("header button[phx-target='#search-palette']", "Search")
        |> render_click()

      assert html =~ "Search everything"

      html =
        view
        |> form("#search-palette-form", %{"q" => "Northside"})
        |> render_change()

      assert html =~ "Dana Rivera"
      assert html =~ "Northside Siding"
    end
  end

  describe "sequence editor" do
    test "refuses to activate a sequence with no emails", ctx do
      empty = sequence_fixture(ctx.project, name: "Empty")
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/sequences/#{empty.id}")

      html = view |> element("button", "Activate") |> render_click()

      assert html =~ "Add at least one email"
      assert Outreach.get_sequence!(empty.id).status == "draft"
    end

    test "previews the step against a real prospect", ctx do
      {:ok, _view, html} =
        live(
          ctx.conn,
          ~p"/admin/p/#{ctx.project.id}/sequences/#{ctx.sequence.id}/steps/#{ctx.step.id}"
        )

      # The whole point of the preview: merge tags resolved, not shown raw.
      assert html =~ "Quick question about Northside Siding"
      assert html =~ "Hi Dana,"
    end
  end

  describe "prospects" do
    test "unsubscribing from the list suppresses globally", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")

      view
      |> element("button[phx-value-id='#{ctx.prospect.id}']", "Unsubscribe")
      |> render_click()

      assert Outreach.suppressed?(ctx.prospect.email)
    end

    test "search filters the list", ctx do
      prospect_fixture(ctx.project, first_name: "Zed", company: "Zenith Gutters")
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")

      html =
        view
        |> form("#prospect-filters", %{"search" => "Zenith", "status" => "all"})
        |> render_change()

      assert html =~ "Zenith Gutters"
      refute html =~ "Northside Siding"
    end
  end
end
