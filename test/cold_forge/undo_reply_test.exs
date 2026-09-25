defmodule ColdForge.UndoReplyTest do
  @moduledoc """
  Reversing a reply, for the false positives: an auto-responder that got past
  the `Auto-Submitted` check, or a reply matched to the wrong person by
  address. The important limit is that it resumes only what the reply stopped —
  an unsubscribe is not undone by it.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Inbox, Outreach, Survey}

  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step_fixture(campaign, %{"subject" => "One"})
    step_fixture(campaign, %{"subject" => "Two", "delay_days" => 3})
    campaign = Outreach.get_campaign!(campaign.id)
    prospect = prospect_fixture(project)
    {:ok, enrollment} = Outreach.enroll_prospect(campaign, prospect)

    %{project: project, campaign: campaign, prospect: prospect, enrollment: enrollment}
  end

  test "puts the prospect back in the campaign", ctx do
    {:ok, prospect} = Outreach.mark_replied(ctx.prospect)
    assert Repo.reload(ctx.enrollment).status == "stopped"

    {:ok, prospect} = Outreach.undo_reply(prospect)

    assert prospect.status == "active"
    refute prospect.replied_at

    enrollment = Repo.reload(ctx.enrollment)
    assert enrollment.status == "active"
    refute enrollment.stopped_reason
    assert enrollment.next_send_at
  end

  test "schedules the resumed send inside the send window", ctx do
    {:ok, prospect} = Outreach.mark_replied(ctx.prospect)
    {:ok, _} = Outreach.undo_reply(prospect)

    # The original slot is in the past by definition, and the alternative to
    # rescheduling is mail going out at four in the morning.
    local =
      Repo.reload(ctx.enrollment).next_send_at
      |> DateTime.shift_zone!(ctx.project.timezone)

    assert local.hour >= ctx.campaign.send_window_start
    assert local.hour < ctx.campaign.send_window_end
    assert Date.day_of_week(DateTime.to_date(local)) in ctx.campaign.send_days
  end

  test "does not resume an enrollment stopped by an unsubscribe", ctx do
    {:ok, prospect} = Outreach.unsubscribe_prospect(ctx.prospect)

    assert {:error, :not_replied} = Outreach.undo_reply(prospect)
    assert Repo.reload(ctx.enrollment).status == "stopped"
    assert Outreach.suppressed?(prospect.email)
  end

  test "an unsubscribe after a reply survives the undo", ctx do
    {:ok, prospect} = Outreach.mark_replied(ctx.prospect)
    {:ok, prospect} = Outreach.unsubscribe_prospect(prospect)

    assert {:error, :not_replied} = Outreach.undo_reply(prospect)
    assert Repo.reload(prospect).status == "unsubscribed"
  end

  test "refuses anyone who did not reply", ctx do
    assert {:error, :not_replied} = Outreach.undo_reply(ctx.prospect)
  end

  test "keeps the reply itself", ctx do
    {:ok, _} =
      Inbox.receive_email(%{
        from: ctx.prospect.email,
        subject: "Automatic reply",
        body: "I am out of the office"
      })

    prospect = Repo.reload(ctx.prospect)
    {:ok, _} = Outreach.mark_replied(prospect)
    {:ok, _} = Outreach.undo_reply(Repo.reload(prospect))

    # The reply happened. Deleting the record to change a status would lose the
    # evidence for why the status was ever set.
    assert length(Inbox.list_replies(ctx.project.id)) == 1
  end

  test "resumes a campaign stopped by a survey answer", ctx do
    {:ok, survey} = Survey.create_survey(%{project_id: ctx.project.id, name: "What hurts"})

    {:ok, _} =
      Survey.create_question(survey, %{
        "kind" => "choice",
        "prompt" => "Worst bit?",
        "options" => "Scheduling\nInvoicing"
      })

    {:ok, _} =
      Repo.reload(ctx.enrollment)
      |> Ecto.Changeset.change(status: "stopped", stopped_reason: "answered", next_send_at: nil)
      |> Repo.update()

    {:ok, prospect} = Outreach.mark_replied(ctx.prospect)
    {:ok, _} = Outreach.undo_reply(prospect)

    assert Repo.reload(ctx.enrollment).status == "active"
  end
end
