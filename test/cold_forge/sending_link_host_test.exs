defmodule ColdForge.SendingLinkHostTest do
  @moduledoc "Each brand's emails link to that brand's own domain."
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures
  import Swoosh.TestAssertions

  alias ColdForge.{Outreach, Sending}
  alias ColdForge.Outreach.Project

  describe "base_url/1" do
    test "uses the project's link host when it has one" do
      assert Sending.base_url(%Project{link_host: "get.exteriorpro.io"}) ==
               "https://get.exteriorpro.io"
    end

    test "falls back to the app's own address" do
      assert Sending.base_url(%Project{link_host: nil}) == ColdForgeWeb.Endpoint.url()
      assert Sending.base_url(nil) == ColdForgeWeb.Endpoint.url()
    end
  end

  describe "the link_host setting" do
    test "keeps the host out of a pasted URL" do
      project = project_fixture()

      assert {:ok, project} =
               Outreach.update_project(project, %{"link_host" => " https://Hello.Furizzma.com/ "})

      assert project.link_host == "hello.furizzma.com"
    end

    test "blank clears it" do
      project = project_fixture(%{link_host: "get.exteriorpro.io"})
      assert {:ok, project} = Outreach.update_project(project, %{"link_host" => ""})
      assert project.link_host == nil
    end

    test "refuses something that isn't a host" do
      project = project_fixture()

      for bad <- ["exteriorpro", "get exteriorpro.io", "kris@get.exteriorpro.io"] do
        assert {:error, changeset} = Outreach.update_project(project, %{"link_host" => bad})
        assert "must be a host name like get.exteriorpro.io" in errors_on(changeset).link_host
      end
    end
  end

  describe "a sent email" do
    test "links, unsubscribes and tracks on the project's own domain" do
      project = project_fixture(%{link_host: "hello.furizzma.com"})
      campaign = campaign_fixture(project)

      step =
        step_fixture(campaign, %{
          "body" => "Hi {{first_name|there}},\n\nSee https://furizzma.com/shelters"
        })

      prospect = prospect_fixture(project)

      {:ok, _message} = Sending.deliver_step(prospect, step, project)

      assert_email_sent(fn email ->
        assert email.text_body =~ "https://hello.furizzma.com/u/"
        assert email.text_body =~ "https://hello.furizzma.com/c/"
        assert email.html_body =~ "https://hello.furizzma.com/o/"
        refute email.text_body =~ ColdForgeWeb.Endpoint.url()
        assert email.headers["List-Unsubscribe"] =~ "https://hello.furizzma.com/u/"
      end)
    end
  end
end
