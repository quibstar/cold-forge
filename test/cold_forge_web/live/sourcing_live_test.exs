defmodule ColdForgeWeb.AdminLive.SourcingTest do
  @moduledoc """
  Saved searches, and the review queue each one fills.
  """
  use ColdForgeWeb.ConnCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Repo
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Org, Source}

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")
    %{conn: log_in_user(conn, user_fixture()), project: project}
  end

  defp source_fixture(project, attrs \\ %{}) do
    {:ok, source} =
      Sourcing.create_source(
        Map.merge(
          %{
            name: "ExteriorPro — West Michigan #{System.unique_integer([:positive])}",
            project_id: project.id,
            provider: "places",
            segments: ["roofing"],
            localities: ["Grand Rapids, MI"]
          },
          attrs
        )
      )

    source
  end

  defp org_fixture(source, attrs \\ %{}) do
    base = %{
      name: "Summit Roofing LLC",
      segment: "roofing",
      provider: "places",
      source_ref: "place-#{System.unique_integer([:positive])}",
      source_id: source.id,
      website: "https://summitroofing.test"
    }

    %Org{} |> Org.discovery_changeset(Map.merge(base, attrs)) |> Repo.insert!()
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

  describe "the list of saved searches" do
    test "says what to do when there are none", %{conn: conn, project: project} do
      {:ok, _live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing")
      assert html =~ "No searches yet"
    end

    test "shows each source, what it looks for and where it lands", %{
      conn: conn,
      project: project
    } do
      source_fixture(project, %{
        name: "ExteriorPro — West Michigan",
        segments: ["roofing", "gutters"],
        localities: ["Grand Rapids, MI", "Holland, MI"]
      })

      {:ok, _live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing")

      assert html =~ "ExteriorPro — West Michigan"
      assert html =~ "Roofing and Gutters"
      assert html =~ "2 places"
      assert html =~ "ExteriorPro"
      assert html =~ "never run"
    end
  end

  describe "creating one" do
    test "needs a segment and somewhere to look", %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      html =
        live
        |> form("#source-form", source: %{name: "Nowhere", provider: "places"})
        |> render_submit()

      assert html =~ "name at least one thing to look for"
      assert html =~ "add at least one place to search"
    end

    test "shows what a run will search and roughly cost, as you type",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      html =
        live
        |> form("#source-form",
          source: %{
            name: "ExteriorPro — Michigan",
            provider: "places",
            segments_text: ~s(Roofing, "Window & Doors"),
            localities_text: "Michigan"
          }
        )
        |> render_change()

      assert has_element?(live, "#source-plan")
      assert html =~ "Michigan becomes its"
      assert html =~ "window and door contractor"
      assert html =~ "about $"
    end

    test "the run button says what it will cost before it starts",
         %{conn: conn, project: project} do
      source = source_fixture(project, %{localities: ["Michigan"]})
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      assert has_element?(live, "#run-plan")
      assert has_element?(live, "button[phx-click='run'][data-confirm*='Google']")
    end

    test "parses the towns out of the textarea, one per line",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      live
      |> form("#source-form",
        source: %{
          name: "ExteriorPro — Lakeshore",
          provider: "places",
          segments_text: "Roofing, Siding",
          localities_text: "Grand Rapids, MI\nHolland, MI\n\n  Muskegon, MI  \n"
        }
      )
      |> render_submit()

      source = Repo.get_by!(Source, name: "ExteriorPro — Lakeshore")
      assert source.localities == ["Grand Rapids, MI", "Holland, MI", "Muskegon, MI"]
      assert source.segments == ["roofing", "siding"]
      assert source.project_id == project.id
    end

    test "refuses a segment the provider can't search for", %{project: project} do
      assert {:error, changeset} =
               Sourcing.create_source(%{
                 name: "Wrong segment",
                 project_id: project.id,
                 provider: "overpass",
                 segments: ["breeder"],
                 localities: ["US-MI"]
               })

      assert {"overpass can't search for breeder." <> _, _} = changeset.errors[:segments_text]
    end
  end

  describe "one source's results" do
    test "shows the address, how it was published, and the page it came from",
         %{conn: conn, project: project} do
      source = source_fixture(project)
      org_fixture(source) |> with_address()

      {:ok, _live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      assert html =~ "Summit Roofing LLC"
      assert html =~ "office@summitroofing.test"
      assert html =~ "mailto link"
      assert html =~ "https://summitroofing.test/contact"
    end

    test "only shows this source's organisations", %{conn: conn, project: project} do
      mine = source_fixture(project, %{name: "Mine"})
      theirs = source_fixture(project, %{name: "Theirs"})

      org_fixture(mine, %{name: "Belongs To Mine"}) |> with_address()
      org_fixture(theirs, %{name: "Belongs To Theirs"}) |> with_address()

      {:ok, _live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{mine.id}")

      assert html =~ "Belongs To Mine"
      refute html =~ "Belongs To Theirs"
    end

    test "promoting uses the source's project, with no asking", %{conn: conn, project: project} do
      source = source_fixture(project)
      org = org_fixture(source) |> with_address()

      {:ok, live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      # No dropdown anywhere: the destination is settled when the source is
      # made, and stated once at the top rather than on three hundred rows.
      # No project field and no dropdown anywhere: being inside the project is
      # the answer to "which project".
      refute html =~ ~s(name="project_id")
      refute html =~ ~s(name="source[project_id]")

      live
      |> element(~s(button[phx-click="promote"][phx-value-org_id="#{org.id}"]))
      |> render_click()

      prospect = Repo.one!(ColdForge.Outreach.Prospect)
      assert prospect.project_id == project.id
      assert prospect.source == "https://summitroofing.test/contact"
      assert Repo.get!(Org, org.id).status == "promoted"
    end

    test "a no-solicitation notice is shown and there is no way to promote",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      org_fixture(source, %{name: "Asked Us Not To"})
      |> with_address(%{no_solicitation: true, notice_text: "No unsolicited commercial email."})

      {:ok, live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      assert html =~ "asked not to be solicited"
      assert html =~ "No unsolicited commercial email."
      refute has_element?(live, ~s(button[phx-click="promote"]))
    end

    test "a phone-only organisation offers the call list", %{conn: conn, project: project} do
      source = source_fixture(project)
      org = org_fixture(source, %{website: nil, phone: "(616) 555-0101", name: "Phone Only"})
      {:ok, _} = Sourcing.reject(org, :no_address_published)

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      rejected = live |> element(~s(button[phx-value-status="rejected"])) |> render_click()
      assert rejected =~ "Phone Only"
      assert rejected =~ "Call list"
    end

    test "adds every ready organisation at once, skipping the ones that aren't",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      org_fixture(source, %{name: "Has An Address"}) |> with_address()

      org_fixture(source, %{name: "Also Fine", source_ref: "p2"})
      |> with_address(%{email: "hello@alsofine.test"})

      org_fixture(source, %{name: "Asked Us Not To", source_ref: "p3"})
      |> with_address(%{no_solicitation: true, notice_text: "No unsolicited commercial email."})

      org_fixture(source, %{name: "Not Crawled Yet", source_ref: "p4"})

      {:ok, live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      assert html =~ "Add all 2"

      live |> element(~s(button[phx-click="promote_ready"])) |> render_click()

      companies =
        ColdForge.Outreach.Prospect
        |> Repo.all()
        |> Enum.map(& &1.company)
        |> Enum.sort()

      assert companies == ["Also Fine", "Has An Address"]
      # The notice decides, and an uncrawled row has nothing to decide on yet.
      refute "Asked Us Not To" in companies
      refute "Not Crawled Yet" in companies
    end

    test "two listings sharing an address become one prospect, not two",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      # Places returns the same company twice when it has two locations, and
      # both carry the same office address. Seen for real with Above Roofing.
      org_fixture(source, %{name: "Above Roofing", source_ref: "loc-1"})
      |> with_address(%{email: "office@aboveroofing.test"})

      org_fixture(source, %{name: "Above Roofing", source_ref: "loc-2"})
      |> with_address(%{email: "office@aboveroofing.test"})

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      html = live |> element(~s(button[phx-click="promote_ready"])) |> render_click()

      assert Repo.aggregate(ColdForge.Outreach.Prospect, :count) == 1
      # And it says so rather than claiming two.
      assert html =~ "Added 1"
      assert html =~ "1 skipped, already there"
    end

    test "running a search queues the work and says so", %{conn: conn, project: project} do
      source = source_fixture(project, %{localities: ["Grand Rapids, MI", "Holland, MI"]})

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")

      html = live |> element(~s(button[phx-click="run"])) |> render_click()
      assert html =~ "Searching"

      assert_enqueued(worker: ColdForge.Workers.RunSource, args: %{source_id: source.id})
    end
  end
end
