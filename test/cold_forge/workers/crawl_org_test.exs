defmodule ColdForge.Workers.CrawlOrgTest do
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  alias ColdForge.Repo
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Org
  alias ColdForge.Workers.CrawlOrg

  defp org_fixture(attrs \\ %{}) do
    base = %{
      name: "Summit Roofing LLC",
      segment: "roofing",
      provider: "places",
      source_ref: "place-#{System.unique_integer([:positive])}",
      website: "https://summitroofing.test",
      # Places nearly always returns a number, and every scenario below ends
      # "goes to the call list" — which it cannot do without one.
      phone: "(616) 555-0101"
    }

    %Org{}
    |> Org.discovery_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "rows that need no network" do
    test "an organisation with no website is rejected, not retried forever" do
      org = org_fixture(%{website: nil})
      assert org.status == "needs_website"

      assert :ok = perform_job(CrawlOrg, %{org_id: org.id})

      reloaded = Repo.get!(Org, org.id)
      assert reloaded.status == "rejected"
      assert reloaded.reject_reason == "no_website"
    end

    test "an already settled organisation is left alone" do
      org = org_fixture()
      {:ok, _} = Sourcing.reject(org, :no_address_published)

      assert :ok = perform_job(CrawlOrg, %{org_id: org.id})

      reloaded = Repo.get!(Org, org.id)
      assert reloaded.reject_reason == "no_address_published"
    end
  end

  describe "a look that finds no address" do
    test "files the place as phone-only" do
      org = org_fixture()

      {:ok, org} = Sourcing.record_nothing_found(org)

      assert org.status == "rejected"
      assert org.reject_reason == "no_address_published"
      assert Sourcing.view_of(org) == "phone"
    end

    test "keeps an address an earlier look already found" do
      org = org_fixture()

      {:ok, org} =
        org
        |> Org.crawl_changeset(%{email: "office@summitroofing.test", status: "fetched"})
        |> Repo.update()

      {:ok, org} = Sourcing.record_nothing_found(org)

      assert org.status == "fetched"
      assert org.email == "office@summitroofing.test"
      assert Sourcing.view_of(org) == "email"
    end
  end

  describe "a website that can't be read on any try" do
    test "fails the early tries, so they're retried" do
      assert_raise Ecto.NoResultsError, fn ->
        perform_job(CrawlOrg, %{org_id: Ecto.UUID.generate()}, attempt: 1)
      end
    end

    test "is settled on the last try instead of left checking for ever" do
      assert :ok = perform_job(CrawlOrg, %{org_id: Ecto.UUID.generate()}, attempt: 3)
    end

    test "with no number to call, it goes to Need a number instead" do
      {:ok, org} = Sourcing.record_unreachable(org_fixture(%{phone: nil}))

      # The Phone only tab used to show these. The Add all button filtered them
      # out, so the tab offered rows the button would not add — which is how
      # forty of them sat there looking actionable.
      assert Sourcing.view_of(org) == "no_number"
      refute org in Sourcing.list_orgs(source_id: org.source_id, view: "phone")
    end

    test "goes to the call list" do
      {:ok, org} = Sourcing.record_unreachable(org_fixture())

      assert org.status == "rejected"
      assert org.reject_reason == "unreachable"
      assert Sourcing.view_of(org) == "phone"
    end

    test "keeps an address an earlier try already found" do
      {:ok, org} =
        org_fixture()
        |> Org.crawl_changeset(%{email: "office@summitroofing.test", status: "fetched"})
        |> Repo.update()

      {:ok, org} = Sourcing.record_unreachable(org)
      assert Sourcing.view_of(org) == "email"
    end
  end

  describe "a host that is never free" do
    # The host's next turn is a minute away, and nothing has been read: the
    # check waits on the queue — but only so many times.
    setup do
      host = "busy-#{System.unique_integer([:positive])}.test"
      :ok = ColdForge.Sourcing.Politeness.put_robots(host, nil)
      :ok = ColdForge.Sourcing.Politeness.reserve(host, 60)
      %{org: org_fixture(%{website: "https://#{host}"})}
    end

    test "waits its turn on the queue", %{org: org} do
      assert {:snooze, seconds} = perform_job(CrawlOrg, %{org_id: org.id})
      assert seconds > 5
      assert Repo.get!(Org, org.id).status == "discovered"
    end

    test "stops waiting after three turns and goes to the call list", %{org: org} do
      assert {:snooze, _} = perform_job(CrawlOrg, %{org_id: org.id}, meta: %{"snoozed" => 2})
      assert :ok = perform_job(CrawlOrg, %{org_id: org.id}, meta: %{"snoozed" => 3})

      reloaded = Repo.get!(Org, org.id)
      assert reloaded.reject_reason == "unreachable"
      assert Sourcing.view_of(reloaded) == "phone"
    end
  end

  describe "the discovery changeset decides what gets crawled" do
    test "a row with a website is crawlable" do
      org = org_fixture()
      assert org.status == "discovered"
      assert org in Sourcing.crawlable()
    end

    test "a row without one waits for a website instead" do
      org = org_fixture(%{website: nil})
      refute org in Sourcing.crawlable()
    end

    test "crawlable can be narrowed to one segment" do
      roofer = org_fixture()
      shelter = org_fixture(%{segment: "shelter", name: "Harbor Humane"})

      roofing = Sourcing.crawlable(segment: "roofing")
      assert roofer in roofing
      refute shelter in roofing
    end

    test "the same row from the same source twice is stored once" do
      ref = "place-dup-#{System.unique_integer([:positive])}"
      attrs = %{name: "A Co", segment: "roofing", provider: "places", source_ref: ref}

      assert {:ok, %{inserted: 1, skipped: 1}} =
               Sourcing.record_discovered([attrs, attrs])
    end
  end

  describe "promoting to a prospect" do
    setup do
      %{project: ColdForge.OutreachFixtures.project_fixture()}
    end

    test "carries the source URL into the prospect, so the list explains itself",
         %{project: project} do
      org =
        org_fixture()
        |> Org.crawl_changeset(%{
          email: "office@summitroofing.test",
          email_source_url: "https://summitroofing.test/contact",
          email_presentation: "mailto",
          status: "fetched"
        })
        |> Repo.update!()

      assert {:ok, {prospect, org}} = Sourcing.promote(org, project.id)

      assert prospect.email == "office@summitroofing.test"
      assert prospect.company == "Summit Roofing LLC"
      assert prospect.source == "https://summitroofing.test/contact"
      assert prospect.industry == "roofing"
      assert prospect.notes =~ "published as mailto"

      assert org.status == "promoted"
      assert org.prospect_id == prospect.id
    end

    test "an organisation with only a phone becomes a callable prospect",
         %{project: project} do
      org = org_fixture(%{phone: "(616) 555-0101", website: nil})
      {:ok, _} = Sourcing.reject(org, :no_address_published)
      org = Repo.get!(Org, org.id)

      assert {:ok, {prospect, _org}} = Sourcing.promote(org, project.id)

      refute prospect.email
      assert prospect.phone == "(616) 555-0101"
      # Reachable, but only down the phone — which is the whole point of
      # keeping these rather than discarding them.
      refute ColdForge.Outreach.Prospect.mailable?(prospect)
    end
  end
end
