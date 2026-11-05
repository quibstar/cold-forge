defmodule ColdForge.DoNotContactTest do
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{DoNotContact, Outreach, Repo}
  alias ColdForge.Calling.Call
  alias ColdForge.Outreach.Enrollment

  setup do
    project = project_fixture(name: "ExteriorPro")
    %{project: project}
  end

  describe "matching" do
    test "names compare loosely and by their start" do
      assert DoNotContact.normalize("D’Angelo & Sons Roofing, LLC") ==
               DoNotContact.normalize("D'Angelo and Sons Roofing")

      entries = [%{name: "High Point Roofing", domain: nil}]

      assert DoNotContact.match_entries(entries, %{
               company: "High Point Roofing & Construction, LLC"
             })

      refute DoNotContact.match_entries(entries, %{company: "Big High Point Roofing"})
    end

    test "a longer name doesn't catch a shorter one" do
      entries = [%{name: "Premier Roofing & Exteriors", domain: nil}]
      refute DoNotContact.match_entries(entries, %{company: "Premier Roofing"})
    end

    test "a domain catches the website or the email, under any name" do
      entries = [%{name: "Premier Roofing & Exteriors", domain: "gopremier.net"}]

      assert DoNotContact.match_entries(entries, %{
               company: "Anything",
               email: "estimates@gopremier.net"
             })

      assert DoNotContact.match_entries(entries, %{website: "https://www.gopremier.net/?utm=x"})
    end

    test "domains are stored bare" do
      assert DoNotContact.domain("https://www.Foo.com/contact") == "foo.com"
      assert DoNotContact.domain("sales@foo.com") == "foo.com"
      assert DoNotContact.domain("foo.com/x") == "foo.com"
      assert DoNotContact.domain(" ") == nil
    end
  end

  describe "adding a company" do
    test "stops the prospects already there, and keeps them", %{project: project} do
      prospect =
        prospect_fixture(project, %{
          company: "High Point Roofing & Construction",
          email: "hp@hp.com"
        })

      campaign = campaign_fixture(project)
      step_fixture(campaign)
      {:ok, enrollment} = Outreach.enroll_prospect(Outreach.get_campaign!(campaign.id), prospect)

      assert {:ok, {_entry, 1}} = DoNotContact.add(project.id, %{"name" => "High Point Roofing"})

      assert Repo.reload(enrollment).status == "stopped"
      assert Outreach.suppressed?("hp@hp.com")
      assert [%Call{outcome: "not_interested"}] = Repo.all(Call)
      assert Repo.reload(prospect)
      assert Repo.reload(prospect).next_call_at == nil
      assert [_] = DoNotContact.caught(project.id)
    end

    test "a prospect caught twice gets one call record", %{project: project} do
      prospect_fixture(project, %{company: "Valentine Roofing", email: "v@v.com"})
      {:ok, _} = DoNotContact.add(project.id, %{"name" => "Valentine Roofing"})
      {:ok, _} = DoNotContact.add(project.id, %{"name" => "Valentine"})
      assert [_] = Repo.all(Call)
    end

    test "is per project", %{project: project} do
      other = project_fixture(name: "Furizzma")
      prospect_fixture(other, %{company: "High Point Roofing", email: "a@b.com"})

      assert {:ok, {_entry, 0}} = DoNotContact.add(project.id, %{"name" => "High Point Roofing"})
      refute Outreach.suppressed?("a@b.com")
    end

    test "needs a name", %{project: project} do
      assert {:error, changeset} = DoNotContact.add(project.id, %{"name" => " "})
      assert %{name: [_]} = errors_on(changeset)
    end
  end

  describe "once a company is listed" do
    setup %{project: project} do
      {:ok, _} =
        DoNotContact.add(project.id, %{"name" => "Altec Roofing", "domain" => "altec.com"})

      :ok
    end

    test "it can't be added as a prospect, by name or by website", %{project: project} do
      assert {:error, changeset} =
               Outreach.create_prospect(%{
                 project_id: project.id,
                 company: "Altec Roofing",
                 email: "x@y.com"
               })

      assert %{company: ["is on the do-not-contact list (Altec Roofing)"]} = errors_on(changeset)

      assert {:error, _} =
               Outreach.create_prospect(%{
                 project_id: project.id,
                 company: "Some Other Name",
                 email: "owner@altec.com"
               })

      assert {:ok, _} =
               Outreach.create_prospect(%{
                 project_id: project.id,
                 company: "Henderson",
                 email: "h@h.com"
               })
    end

    test "it can't be enrolled", %{project: project} do
      # Already there from before the list, under a name that slipped past.
      prospect =
        Repo.insert!(%Outreach.Prospect{
          project_id: project.id,
          company: "Altec Roofing Co",
          email: "a@altec.com",
          unsubscribe_token: "t1"
        })

      campaign = campaign_fixture(project)
      step_fixture(campaign)

      assert {:error, :do_not_contact} =
               Outreach.enroll_prospect(Outreach.get_campaign!(campaign.id), prospect)

      refute Repo.exists?(Enrollment)
    end
  end
end
