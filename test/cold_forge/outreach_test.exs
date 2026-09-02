defmodule ColdForge.OutreachTest do
  @moduledoc """
  Enrollment and the stop conditions. These matter more than the CRUD: a bug
  here means somebody who asked to be left alone gets mailed again.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step_fixture(campaign)
    %{project: project, campaign: Outreach.get_campaign!(campaign.id)}
  end

  describe "enroll_prospect/2" do
    test "schedules the first step inside the send window", ctx do
      prospect = prospect_fixture(ctx.project)

      {:ok, enrollment} = Outreach.enroll_prospect(ctx.campaign, prospect)

      assert enrollment.status == "active"
      assert enrollment.current_position == 0

      local = DateTime.shift_zone!(enrollment.next_send_at, ctx.project.timezone)
      assert local.hour >= ctx.campaign.send_window_start
      assert local.hour < ctx.campaign.send_window_end
      assert Date.day_of_week(DateTime.to_date(local)) in ctx.campaign.send_days
    end

    test "refuses a suppressed address", ctx do
      prospect = prospect_fixture(ctx.project)
      Outreach.suppress(prospect.email, "manual")

      assert {:error, :suppressed} = Outreach.enroll_prospect(ctx.campaign, prospect)
    end

    test "refuses a campaign with no steps", ctx do
      empty = campaign_fixture(ctx.project, name: "Empty")
      prospect = prospect_fixture(ctx.project)

      assert {:error, :no_steps} = Outreach.enroll_prospect(empty, prospect)
    end

    test "will not enroll the same prospect twice", ctx do
      prospect = prospect_fixture(ctx.project)

      assert {:ok, _} = Outreach.enroll_prospect(ctx.campaign, prospect)
      assert {:error, changeset} = Outreach.enroll_prospect(ctx.campaign, prospect)
      assert "is already enrolled in this campaign" in errors_on(changeset).campaign_id
    end
  end

  describe "enroll_prospects/2" do
    test "skips who it can't mail rather than failing the whole batch", ctx do
      ok = prospect_fixture(ctx.project)
      blocked = prospect_fixture(ctx.project)
      Outreach.suppress(blocked.email, "manual")

      {:ok, result} = Outreach.enroll_prospects(ctx.campaign, [ok.id, blocked.id])

      assert result == %{enrolled: 1, skipped: 1}
    end
  end

  describe "unsubscribe_prospect/1" do
    test "suppresses globally and stops every campaign they're in", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, enrollment} = Outreach.enroll_prospect(ctx.campaign, prospect)

      {:ok, prospect} = Outreach.unsubscribe_prospect(prospect)

      assert prospect.status == "unsubscribed"
      assert prospect.unsubscribed_at
      assert Outreach.suppressed?(prospect.email)

      enrollment = Repo.reload(enrollment)
      assert enrollment.status == "stopped"
      assert enrollment.stopped_reason == "unsubscribed"
      assert enrollment.next_send_at == nil
    end

    test "suppression reaches a different project's prospect with the same email", ctx do
      prospect = prospect_fixture(ctx.project, email: "same@example.com")
      other_project = project_fixture()
      other = prospect_fixture(other_project, email: "same@example.com")

      {:ok, _} = Outreach.unsubscribe_prospect(prospect)

      other_campaign = campaign_fixture(other_project)
      step_fixture(other_campaign)
      assert {:error, :suppressed} = Outreach.enroll_prospect(other_campaign, other)
    end
  end

  describe "mark_replied/1" do
    test "stops the drip so a conversation isn't interrupted by a follow-up", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, enrollment} = Outreach.enroll_prospect(ctx.campaign, prospect)

      {:ok, prospect} = Outreach.mark_replied(prospect)

      assert prospect.status == "replied"
      assert Repo.reload(enrollment).stopped_reason == "replied"
      # Replying is not opting out — they stay mailable for other projects.
      refute Outreach.suppressed?(prospect.email)
    end
  end

  describe "delete_step/1" do
    test "closes the gap so positions stay a dense run", ctx do
      one = hd(ctx.campaign.steps)
      two = step_fixture(ctx.campaign, %{"subject" => "Two"})
      three = step_fixture(ctx.campaign, %{"subject" => "Three"})

      {:ok, :ok} = Outreach.delete_step(two)

      assert Repo.reload(one).position == 1
      assert Repo.reload(three).position == 2
    end
  end

  describe "project branding" do
    test "requires a hex brand colour", ctx do
      assert {:error, changeset} = Outreach.update_project(ctx.project, %{brand_color: "teal"})
      assert "must be a hex colour like #0f766e" in errors_on(changeset).brand_color
    end

    test "requires an absolute logo URL", ctx do
      # A relative path would resolve against the recipient's mail client, not
      # our site — it's a broken image, not a logo.
      assert {:error, changeset} = Outreach.update_project(ctx.project, %{logo_url: "/logo.png"})
      assert errors_on(changeset).logo_url != []
    end

    test "an empty logo URL is allowed", ctx do
      assert {:ok, _} = Outreach.update_project(ctx.project, %{logo_url: ""})
    end
  end

  describe "activate_campaign/1" do
    test "refuses a campaign with no emails in it", ctx do
      empty = campaign_fixture(ctx.project, name: "Empty")
      assert {:error, :no_steps} = Outreach.activate_campaign(empty)
    end

    test "activates once there's a step", ctx do
      assert {:ok, campaign} = Outreach.activate_campaign(ctx.campaign)
      assert campaign.status == "active"
    end
  end
end
