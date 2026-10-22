defmodule ColdForgeWeb.AdminLive.SourcingTest do
  @moduledoc """
  The review queue, which exists so nothing reaches a send list unlooked-at.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Repo
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Org

  defp org_fixture(attrs) do
    base = %{
      name: "Summit Roofing LLC",
      segment: "roofing",
      source: "places",
      source_ref: "place-#{System.unique_integer([:positive])}",
      website: "https://summitroofing.test"
    }

    %Org{}
    |> Org.discovery_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp with_address(org, attrs \\ %{}) do
    org
    |> Org.crawl_changeset(
      Map.merge(
        %{
          email: "office@summitroofing.test",
          email_source_url: "https://summitroofing.test/contact",
          email_presentation: "mailto",
          status: "fetched"
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture()), project: project_fixture(name: "ExteriorPro")}
  end

  test "shows the address, how it was published, and a link to the page it came from",
       %{conn: conn} do
    org_fixture(%{}) |> with_address()

    {:ok, _live, html} = live(conn, ~p"/admin/sourcing")

    assert html =~ "Summit Roofing LLC"
    assert html =~ "office@summitroofing.test"
    assert html =~ "published as mailto"
    # The evidence has to be one click away, or nobody checks it.
    assert html =~ "https://summitroofing.test/contact"
  end

  test "filters by status", %{conn: conn} do
    org_fixture(%{name: "Has An Address"}) |> with_address()
    org_fixture(%{name: "Not Crawled Yet"})

    {:ok, live, html} = live(conn, ~p"/admin/sourcing")
    assert html =~ "Has An Address"
    refute html =~ "Not Crawled Yet"

    waiting = live |> element(~s(button[phx-value-status="discovered"])) |> render_click()
    assert waiting =~ "Not Crawled Yet"
    refute waiting =~ "Has An Address"
  end

  test "promoting creates a prospect carrying the source URL", %{conn: conn, project: project} do
    org = org_fixture(%{}) |> with_address()

    {:ok, live, _html} = live(conn, ~p"/admin/sourcing")

    html =
      live
      |> form(~s(form[phx-submit="promote"]), %{org_id: org.id, project_id: project.id})
      |> render_submit()

    assert html =~ "is now a prospect"

    prospect = Repo.one!(ColdForge.Outreach.Prospect)
    assert prospect.email == "office@summitroofing.test"
    assert prospect.source == "https://summitroofing.test/contact"
    assert Repo.get!(Org, org.id).status == "promoted"
  end

  test "promoting without picking a project says so instead of failing quietly",
       %{conn: conn} do
    org_fixture(%{}) |> with_address()

    {:ok, live, _html} = live(conn, ~p"/admin/sourcing")

    html =
      live
      |> form(~s(form[phx-submit="promote"]), %{project_id: ""})
      |> render_submit()

    assert html =~ "Pick a project first"
    assert Repo.aggregate(ColdForge.Outreach.Prospect, :count) == 0
  end

  test "a no-solicitation notice is shown and promotion is disabled", %{conn: conn} do
    org_fixture(%{name: "Asked Us Not To"})
    |> with_address(%{no_solicitation: true, notice_text: "No unsolicited commercial email."})

    {:ok, _live, html} = live(conn, ~p"/admin/sourcing")

    assert html =~ "asks not to be solicited"
    assert html =~ "No unsolicited commercial email."
    # The button renders, but disabled — the notice decides, not the address.
    assert html =~ "disabled"
  end

  test "a phone-only organisation offers the call list rather than a prospect email",
       %{conn: conn, project: project} do
    org = org_fixture(%{website: nil, phone: "(616) 555-0101", name: "Phone Only Roofing"})
    {:ok, _} = Sourcing.reject(org, :no_address_published)

    {:ok, live, html} = live(conn, ~p"/admin/sourcing")

    rejected = live |> element(~s(button[phx-value-status="rejected"])) |> render_click()
    assert rejected =~ "Phone Only Roofing"
    assert rejected =~ "Add to call list"
    refute html =~ "Phone Only Roofing"

    rejected
    |> then(fn _ ->
      live
      |> form(~s(form[phx-submit="promote"]), %{org_id: org.id, project_id: project.id})
      |> render_submit()
    end)

    prospect = Repo.one!(ColdForge.Outreach.Prospect)
    refute prospect.email
    assert prospect.phone == "(616) 555-0101"
  end

  test "marking one not a fit leaves it off", %{conn: conn} do
    org = org_fixture(%{}) |> with_address()

    {:ok, live, _html} = live(conn, ~p"/admin/sourcing")

    live
    |> element(~s(button[phx-click="reject"][phx-value-id="#{org.id}"]))
    |> render_click()

    assert Repo.get!(Org, org.id).reject_reason == "out_of_segment"
  end

  test "an empty status says so rather than rendering nothing", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/sourcing")
    assert html =~ "Nothing at this status"
  end

  test "the sidebar links to it", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/sourcing")
    assert html =~ ~s(href="/admin/sourcing")
  end
end
