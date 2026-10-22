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
    test "says what to do when there are none", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/sourcing")
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

      {:ok, _live, html} = live(conn, ~p"/admin/sourcing")

      assert html =~ "ExteriorPro — West Michigan"
      assert html =~ "Roofing and Gutters"
      assert html =~ "2 places"
      assert html =~ "ExteriorPro"
      assert html =~ "never run"
    end
  end

  describe "creating one" do
    test "needs a project, a segment and somewhere to look", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/sourcing/new")

      html =
        live
        |> form("#source-form", source: %{name: "Nowhere", provider: "places"})
        |> render_submit()

      assert html =~ "name at least one thing to look for"
      assert html =~ "add at least one place to search"
    end

    test "parses the towns out of the textarea, one per line",
         %{conn: conn, project: project} do
      {:ok, live, _html} = live(conn, ~p"/admin/sourcing/new")

      live
      |> form("#source-form",
        source: %{
          name: "ExteriorPro — Lakeshore",
          project_id: project.id,
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

      {:ok, _live, html} = live(conn, ~p"/admin/sourcing/#{source.id}")

      assert html =~ "Summit Roofing LLC"
      assert html =~ "office@summitroofing.test"
      assert html =~ "published as mailto"
      assert html =~ "https://summitroofing.test/contact"
    end

    test "only shows this source's organisations", %{conn: conn, project: project} do
      mine = source_fixture(project, %{name: "Mine"})
      theirs = source_fixture(project, %{name: "Theirs"})

      org_fixture(mine, %{name: "Belongs To Mine"}) |> with_address()
      org_fixture(theirs, %{name: "Belongs To Theirs"}) |> with_address()

      {:ok, _live, html} = live(conn, ~p"/admin/sourcing/#{mine.id}")

      assert html =~ "Belongs To Mine"
      refute html =~ "Belongs To Theirs"
    end

    test "promoting uses the source's project, with no asking", %{conn: conn, project: project} do
      source = source_fixture(project)
      org = org_fixture(source) |> with_address()

      {:ok, live, html} = live(conn, ~p"/admin/sourcing/#{source.id}")
      # The button names the destination instead of offering a dropdown.
      assert html =~ "Add to ExteriorPro"

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

      {:ok, live, html} = live(conn, ~p"/admin/sourcing/#{source.id}")

      assert html =~ "asks not to be solicited"
      assert html =~ "No unsolicited commercial email."
      refute has_element?(live, ~s(button[phx-click="promote"]))
    end

    test "a phone-only organisation offers the call list", %{conn: conn, project: project} do
      source = source_fixture(project)
      org = org_fixture(source, %{website: nil, phone: "(616) 555-0101", name: "Phone Only"})
      {:ok, _} = Sourcing.reject(org, :no_address_published)

      {:ok, live, _html} = live(conn, ~p"/admin/sourcing/#{source.id}")

      rejected = live |> element(~s(button[phx-value-status="rejected"])) |> render_click()
      assert rejected =~ "Phone Only"
      assert rejected =~ "Add to call list"
    end

    test "running a search queues the work and says so", %{conn: conn, project: project} do
      source = source_fixture(project, %{localities: ["Grand Rapids, MI", "Holland, MI"]})

      {:ok, live, _html} = live(conn, ~p"/admin/sourcing/#{source.id}")

      html = live |> element(~s(button[phx-click="run"])) |> render_click()
      assert html =~ "Searching"

      assert_enqueued(worker: ColdForge.Workers.RunSource, args: %{source_id: source.id})
    end
  end
end
