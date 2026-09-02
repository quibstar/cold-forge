defmodule ColdForge.CampaignTest do
  @moduledoc """
  A campaign is emails plus people. A one-email campaign is a single send; add
  more with delays and they become follow-ups. These assert both behave, and
  that neither is a way around the protections.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Enrollment
  alias ColdForge.Workers.{SendMessage, CampaignScheduler}

  setup do
    %{project: project_fixture()}
  end

  describe "a one-email campaign" do
    setup ctx do
      campaign = campaign_fixture(ctx.project, name: "Spring case study")
      step_fixture(campaign)
      %{campaign: Outreach.get_campaign!(campaign.id)}
    end

    test "sends once and finishes", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, _} = Outreach.send_campaign(ctx.campaign, [prospect.id])

      [enrollment] = Outreach.list_enrollments(ctx.campaign.id)
      assert :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

      enrollment = Repo.reload(enrollment)
      assert enrollment.status == "completed"
      assert enrollment.next_send_at == nil
      assert length(Outreach.list_messages(ctx.project.id)) == 1
    end

    test "carries a working unsubscribe link and a tracked link", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, _} = Outreach.send_campaign(ctx.campaign, [prospect.id])

      [enrollment] = Outreach.list_enrollments(ctx.campaign.id)
      assert :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

      [message] = Outreach.list_messages(ctx.project.id)
      assert message.body =~ "/u/#{prospect.unsubscribe_token}"
      assert [_link] = Outreach.get_message!(message.id).tracked_links
    end
  end

  describe "send_campaign/2" do
    setup ctx do
      campaign = campaign_fixture(ctx.project)
      step_fixture(campaign)
      %{campaign: Outreach.get_campaign!(campaign.id)}
    end

    test "activates and enrolls the chosen people", ctx do
      a = prospect_fixture(ctx.project)
      b = prospect_fixture(ctx.project)

      {:ok, result} = Outreach.send_campaign(ctx.campaign, [a.id, b.id])

      assert result == %{enrolled: 2, skipped: 0}
      assert Outreach.get_campaign!(ctx.campaign.id).status == "active"
    end

    test "skips anyone suppressed rather than mailing them", ctx do
      ok = prospect_fixture(ctx.project)
      blocked = prospect_fixture(ctx.project)
      Outreach.suppress(blocked.email, "unsubscribed")

      {:ok, result} = Outreach.send_campaign(ctx.campaign, [ok.id, blocked.id])

      assert result == %{enrolled: 1, skipped: 1}
    end

    test "refuses a campaign with no emails in it", ctx do
      empty = campaign_fixture(ctx.project, name: "Empty")
      prospect = prospect_fixture(ctx.project)

      assert {:error, :no_steps} = Outreach.send_campaign(empty, [prospect.id])
    end

    test "the daily cap paces a big list instead of sending it at once", ctx do
      {:ok, campaign} = Outreach.update_campaign(ctx.campaign, %{daily_cap: 2})
      campaign = Outreach.get_campaign!(campaign.id)

      ids = for _ <- 1..5, do: prospect_fixture(ctx.project).id
      {:ok, %{enrolled: 5}} = Outreach.send_campaign(campaign, ids)

      # Everyone is enrolled, but only the cap becomes due in one pass — this is
      # what stops a campaign from torching the sending domain in an hour.
      Repo.update_all(Enrollment,
        set: [
          next_send_at:
            DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
        ]
      )

      assert :ok = perform_job(CampaignScheduler, %{})
      assert length(all_enqueued(worker: SendMessage)) == 2
    end
  end

  describe "campaign_stats/1" do
    test "counts only this campaign's messages", ctx do
      campaign = campaign_fixture(ctx.project, name: "Counted")
      step_fixture(campaign)
      campaign = Outreach.get_campaign!(campaign.id)

      other = campaign_fixture(ctx.project, name: "Other")
      step_fixture(other)
      other = Outreach.get_campaign!(other.id)

      {:ok, _} = Outreach.send_campaign(campaign, [prospect_fixture(ctx.project).id])
      {:ok, _} = Outreach.send_campaign(other, [prospect_fixture(ctx.project).id])

      for e <- Outreach.list_enrollments(campaign.id) do
        assert :ok = perform_job(SendMessage, %{enrollment_id: e.id})
      end

      assert Outreach.campaign_stats(campaign.id) == %{sent: 1, opened: 0, clicked: 0}
      assert Outreach.campaign_stats(other.id) == %{sent: 0, opened: 0, clicked: 0}
    end

    test "counts an open and a click against the right campaign", ctx do
      campaign = campaign_fixture(ctx.project)
      step_fixture(campaign)
      campaign = Outreach.get_campaign!(campaign.id)

      {:ok, _} = Outreach.send_campaign(campaign, [prospect_fixture(ctx.project).id])
      [enrollment] = Outreach.list_enrollments(campaign.id)
      assert :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

      [message] = Outreach.list_messages(ctx.project.id)
      ColdForge.Tracking.record_open(message.open_token)

      [link] = Outreach.get_message!(message.id).tracked_links
      ColdForge.Tracking.record_click(ColdForge.Tracking.get_tracked_link(link.token))

      assert Outreach.campaign_stats(campaign.id) == %{sent: 1, opened: 1, clicked: 1}
    end
  end

  describe "a multi-email campaign" do
    test "waits the delay before the follow-up", ctx do
      campaign = campaign_fixture(ctx.project)
      step_fixture(campaign, %{"subject" => "One"})
      step_fixture(campaign, %{"subject" => "Two", "delay_days" => 3})
      campaign = Outreach.get_campaign!(campaign.id)

      {:ok, _} = Outreach.send_campaign(campaign, [prospect_fixture(ctx.project).id])
      [enrollment] = Outreach.list_enrollments(campaign.id)

      assert :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

      enrollment = Repo.reload(enrollment)
      assert enrollment.status == "active"
      assert DateTime.diff(enrollment.next_send_at, DateTime.utc_now(), :day) >= 2
    end
  end
end
