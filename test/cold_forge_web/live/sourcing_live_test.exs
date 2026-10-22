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

    test "the state picker adds every town above a population to Where",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      live
      |> form("#source-form", picker: %{mode: "state", state: "MI", min_population: "100000"})
      |> render_change()

      assert has_element?(live, "#town-picker", "Grand Rapids, MI")
      refute has_element?(live, "#town-picker", "Holland, MI")

      live |> element("#add-towns") |> render_click()

      textarea = live |> element("#source_localities_text") |> render()
      assert textarea =~ "Detroit, MI"
      assert textarea =~ "Grand Rapids, MI"
      refute textarea =~ "Holland, MI"
    end

    test "the radius picker adds nearby towns, minus any unticked",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      live
      |> form("#source-form", picker: %{mode: "radius", state: "MI"})
      |> render_change()

      live
      |> form("#source-form",
        picker: %{center: "Grand Rapids, MI", miles: "10", min_population: "1000"}
      )
      |> render_change()

      assert has_element?(live, "#town-picker", "Grandville, MI")

      live
      |> element("input[phx-value-label='Walker, MI']")
      |> render_click()

      live |> element("#add-towns") |> render_click()

      textarea = live |> element("#source_localities_text") |> render()
      assert textarea =~ "Grandville, MI"
      refute textarea =~ "Walker, MI"
    end

    test "adding towns keeps what was already in Where, without repeats",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      live
      |> form("#source-form",
        source: %{
          name: "Mixed",
          provider: "places",
          localities_text: "Toledo, OH\nGrand Rapids, MI"
        },
        picker: %{mode: "state", state: "MI", min_population: "100000"}
      )
      |> render_change()

      live |> element("#add-towns") |> render_click()

      textarea = live |> element("#source_localities_text") |> render()
      assert textarea =~ "Toledo, OH"
      assert length(Regex.scan(~r/Grand Rapids, MI/, textarea)) == 1
    end

    test "OpenStreetMap searches regions, so there's no town picker",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/new")

      live |> form("#source-form", source: %{provider: "overpass"}) |> render_change()

      refute has_element?(live, "#town-picker")
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

    test "adds every place with an email for the drip, skipping the ones that aren't ready",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      org_fixture(source, %{name: "Has An Address"}) |> with_address()

      org_fixture(source, %{name: "Also Fine", source_ref: "p2"})
      |> with_address(%{email: "hello@alsofine.test"})

      org_fixture(source, %{name: "Asked Us Not To", source_ref: "p3"})
      |> with_address(%{no_solicitation: true, notice_text: "No unsolicited commercial email."})

      org_fixture(source, %{name: "Not Crawled Yet", source_ref: "p4"})

      {:ok, live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      assert html =~ "Add 2 for email drip"
      # Its website hasn't been checked yet, so it may still turn up an address.
      assert html =~ "1 websites still being checked"

      live |> element("#add-all-email") |> render_click()

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

      html = live |> element("#add-all-email") |> render_click()

      assert Repo.aggregate(ColdForge.Outreach.Prospect, :count) == 1
      # And it says so rather than claiming two.
      assert html =~ "Added 1"
      assert html =~ "1 already there"
    end

    test "adds every phone-only place for calling, including ones with no website",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      # What a trades search turns up by the hundred: a listing, a phone, no site.
      org_fixture(source, %{name: "No Site Roofing", website: nil, phone: "(616) 555-0101"})
      org_fixture(source, %{name: "No Site, No Phone", website: nil, source_ref: "p2"})

      org_fixture(source, %{name: "Site But No Address", phone: "616-555-0102", source_ref: "p3"})
      |> with_address(%{email: nil, email_source_url: nil, email_presentation: nil})

      org_fixture(source, %{name: "Has An Address", phone: "616-555-0103", source_ref: "p4"})
      |> with_address()

      {:ok, live, html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      assert html =~ "Add 2 for calling"
      assert html =~ "Add 1 for email drip"

      live |> element("#add-all-calls") |> render_click()

      added = Repo.all(ColdForge.Outreach.Prospect)

      assert Enum.map(added, & &1.company) |> Enum.sort() == [
               "No Site Roofing",
               "Site But No Address"
             ]

      assert Enum.all?(added, &is_nil(&1.email))
      # Phone-only, so they're on the call list and can never be emailed.
      assert length(ColdForge.Calling.queue(project.id)) == 2
    end

    test "a shop already a prospect, matched by phone, is linked not added twice",
         %{conn: conn, project: project} do
      {:ok, _} =
        ColdForge.Outreach.create_prospect(%{
          project_id: project.id,
          company: "Imported Earlier",
          phone: "616.555.0101"
        })

      source = source_fixture(project)
      org = org_fixture(source, %{name: "No Site Roofing", website: nil, phone: "(616) 555-0101"})

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      html = live |> element("#add-all-calls") |> render_click()

      assert Repo.aggregate(ColdForge.Outreach.Prospect, :count) == 1
      assert html =~ "1 already there"
      assert Repo.reload(org).status == "promoted"
    end

    test "a page asking not to be solicited keeps a place off the call list too",
         %{conn: conn, project: project} do
      source = source_fixture(project)

      org_fixture(source, %{name: "Asked Us Not To", phone: "616-555-0109"})
      |> with_address(%{email: nil, no_solicitation: true, notice_text: "No solicitors."})

      {:ok, live, _html} = live(conn, ~p"/admin/p/#{project.id}/sourcing/#{source.id}")
      refute has_element?(live, "#add-all-calls")
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
