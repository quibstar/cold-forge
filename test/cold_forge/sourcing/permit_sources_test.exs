defmodule ColdForge.Sourcing.PermitSourcesTest do
  @moduledoc """
  Permit sources: what they accept, the website lookups they queue, "Add all
  and start", and the weekly digest.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach.Enrollment
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Org, Source}
  alias ColdForge.Workers.{FindWebsite, PermitDigest}

  defp permit_source(project, attrs \\ %{}) do
    {:ok, source} =
      Sourcing.create_source(
        Map.merge(
          %{
            name: "Permits — Texas #{System.unique_integer([:positive])}",
            project_id: project.id,
            provider: "permits",
            segments_text: "roofing, siding",
            localities_text: "austin\nsan_antonio"
          },
          attrs
        )
      )

    source
  end

  defp permit_org(source, attrs) do
    %Org{}
    |> Org.discovery_changeset(
      Map.merge(
        %{
          name: "Kanga Roof LLC",
          segment: "roofing",
          provider: "permits",
          source_ref: "austin:#{System.unique_integer([:positive])}",
          source_id: source.id,
          phone: "(512) 388-7663",
          city: "Austin",
          region: "TX",
          raw: %{"permit_city" => "Austin", "permits" => 7, "last_issued" => "2026-11-06"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp found_address(org, email) do
    org
    |> Ecto.Changeset.change(%{website: "https://#{org.id}.test"})
    |> Repo.update!()
    |> Org.crawl_changeset(%{email: email, status: "fetched", email_source_url: "https://x.test"})
    |> Repo.update!()
  end

  test "a permit source takes the cities that have data and the four trades" do
    project = project_fixture()
    source = permit_source(project)

    assert source.segments == ["roofing", "siding"]
    assert Source.queries(source) |> length() == 4

    {:error, changeset} =
      Sourcing.create_source(%{
        name: "Bad",
        project_id: project.id,
        provider: "permits",
        segments_text: "roofing, decks",
        localities_text: "austin\ndallas"
      })

    assert %{segments_text: [segments_error], localities_text: [city_error]} =
             errors_on(changeset)

    assert segments_error =~ "decks"
    assert city_error =~ "dallas"
  end

  test "rows without a website get a lookup queued, and nothing else does" do
    project = project_fixture()
    source = permit_source(project)
    needs = permit_org(source, %{})
    has_site = permit_org(source, %{name: "Has A Site", website: "https://site.test"})

    assert Sourcing.enqueue_website_lookups([needs, has_site]) == 1
    assert_enqueued(worker: FindWebsite, args: %{org_id: needs.id})
    refute_enqueued(worker: FindWebsite, args: %{org_id: has_site.id})
  end

  test "a found website moves the row on to the crawl, keeping the city's phone" do
    project = project_fixture()
    org = project |> permit_source() |> permit_org(%{})

    {:ok, org} =
      Sourcing.record_website(org, %{website: "kangaroof.test", phone: "(512) 000-0000"})

    assert org.status == "discovered"
    assert org.website == "https://kangaroof.test"
    assert org.phone == "(512) 388-7663"
  end

  describe "Add all and start" do
    test "adds everyone with an address and starts only the new ones on the drip" do
      project = project_fixture()
      campaign = campaign_fixture(project, %{name: "Permit contractors - Texas"})
      step_fixture(campaign)
      source = permit_source(project, %{campaign_id: campaign.id})

      source |> permit_org(%{name: "New Shop", phone: nil}) |> found_address("hi@newshop.test")

      # Already on the list, partway through another drip.
      existing = prospect_fixture(project, %{email: "office@already.test"})

      source
      |> permit_org(%{name: "Already Here", phone: nil})
      |> found_address("office@already.test")

      source = Sourcing.get_source!(source.id)

      assert {:ok, %{added: 1, existing: 1, enrolled: 1}} =
               Sourcing.promote_all_and_enroll(source)

      [enrollment] = Repo.all(Enrollment)
      assert enrollment.campaign_id == campaign.id
      refute enrollment.prospect_id == existing.id

      prospect = Repo.get!(ColdForge.Outreach.Prospect, enrollment.prospect_id)
      assert prospect.company == "New Shop"
      assert prospect.custom_fields == %{"permit_city" => "Austin", "permit_count" => "7"}
      assert prospect.notes =~ "7 roofing permits in Austin"
    end

    test "needs a drip set on the source" do
      project = project_fixture()

      assert {:error, :no_campaign} =
               project |> permit_source() |> Sourcing.promote_all_and_enroll()
    end
  end

  test "the digest says what's ready and links to the page" do
    project = project_fixture()
    source = permit_source(project)
    lines = [{source, %{email: 14, calls: 6, checking: 2}}]

    assert PermitDigest.subject(project, lines) =~ "14 new contractors from permits"
    body = PermitDigest.body(project, lines)
    assert body =~ "14 with an email address"
    assert body =~ "6 with a phone and no email"
    assert body =~ "/admin/p/#{project.id}/sourcing/#{source.id}"
    assert body =~ "Nothing is emailed until you click Add all"
  end
end
