defmodule ColdForge.SendingTest do
  @moduledoc """
  Covers the loop the whole app exists for: render a step, tokenise its links,
  send it, and honour the unsubscribe that comes back.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures
  import Swoosh.TestAssertions

  alias ColdForge.{Outreach, Sending, Tracking}

  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step = step_fixture(campaign)
    %{project: project, campaign: campaign, step: step}
  end

  describe "deliver_step/4" do
    test "renders merge tags against the prospect", ctx do
      prospect = prospect_fixture(ctx.project, first_name: "Dana", company: "Northside Siding")

      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)

      assert message.status == "sent"
      assert message.subject == "Quick question about Northside Siding"
      assert message.body =~ "Hi Dana,"
    end

    test "falls back when a merge field is empty", ctx do
      prospect = prospect_fixture(ctx.project, first_name: nil)

      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)

      assert message.body =~ "Hi there,"
      refute message.body =~ "{{"
    end

    test "replaces the landing URL with a tracked redirect", ctx do
      prospect = prospect_fixture(ctx.project)

      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)
      message = Outreach.get_message!(message.id)

      assert [link] = message.tracked_links
      assert link.destination_url == "https://exteriorpro.io/demo"
      # The recipient sees our token, never the destination.
      assert message.body =~ "/c/#{link.token}"
      refute message.body =~ "https://exteriorpro.io/demo"
    end

    test "rewrites a URL that is a prefix of another without mangling it", ctx do
      step =
        step_fixture(ctx.campaign, %{
          "subject" => "Two links",
          "body" => "Site: https://exteriorpro.io and demo: https://exteriorpro.io/demo"
        })

      prospect = prospect_fixture(ctx.project)
      {:ok, message} = Sending.deliver_step(prospect, step, ctx.project)
      message = Outreach.get_message!(message.id)

      destinations = Enum.map(message.tracked_links, & &1.destination_url) |> Enum.sort()
      assert destinations == ["https://exteriorpro.io", "https://exteriorpro.io/demo"]

      # The giveaway for the prefix bug: a token with the longer URL's tail
      # left dangling after it.
      refute message.body =~ ~r{/c/[\w-]+/demo}
    end

    test "appends the unsubscribe link and postal address", ctx do
      prospect = prospect_fixture(ctx.project)

      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)

      assert message.body =~ "/u/#{prospect.unsubscribe_token}"
      assert message.body =~ "123 Main St, Springfield, IL"
    end

    test "sets the one-click unsubscribe headers", ctx do
      prospect = prospect_fixture(ctx.project)

      {:ok, _message} = Sending.deliver_step(prospect, ctx.step, ctx.project)

      assert_email_sent(fn email ->
        assert {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"} in email.headers

        assert Enum.any?(email.headers, fn {k, v} ->
                 k == "List-Unsubscribe" and v =~ prospect.unsubscribe_token
               end)
      end)
    end

    test "refuses to mail a suppressed address", ctx do
      prospect = prospect_fixture(ctx.project)
      Outreach.suppress(prospect.email, "manual")

      assert {:error, :suppressed} = Sending.deliver_step(prospect, ctx.step, ctx.project)
    end

    test "refuses to mail for an inactive project", ctx do
      {:ok, project} = Outreach.update_project(ctx.project, %{active: false})
      prospect = prospect_fixture(ctx.project)

      assert {:error, :project_inactive} = Sending.deliver_step(prospect, ctx.step, project)
    end
  end

  describe "click tracking" do
    test "records the click and appends attribution to the destination", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)
      [link] = Outreach.get_message!(message.id).tracked_links

      destination = Tracking.record_click(Tracking.get_tracked_link(link.token))

      assert destination == "https://exteriorpro.io/demo?cf=#{link.token}"
      assert Repo.reload(link).click_count == 1
    end

    test "an unknown token resolves to nothing rather than raising" do
      assert Tracking.get_tracked_link("not-a-real-token") == nil
    end
  end

  describe "open tracking" do
    test "counts every open but keeps the first timestamp", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, message} = Sending.deliver_step(prospect, ctx.step, ctx.project)

      assert :ok = Tracking.record_open(message.open_token)
      first = Repo.reload(message).first_opened_at

      assert :ok = Tracking.record_open(message.open_token)
      reloaded = Repo.reload(message)

      assert reloaded.open_count == 2
      assert reloaded.first_opened_at == first
    end

    test "an unknown token is not an error" do
      assert :not_found = Tracking.record_open("nope")
    end
  end
end
