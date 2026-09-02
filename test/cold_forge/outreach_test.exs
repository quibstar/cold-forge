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
    sequence = sequence_fixture(project)
    step_fixture(sequence)
    %{project: project, sequence: Outreach.get_sequence!(sequence.id)}
  end

  describe "enroll_prospect/2" do
    test "schedules the first step inside the send window", ctx do
      prospect = prospect_fixture(ctx.project)

      {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)

      assert enrollment.status == "active"
      assert enrollment.current_position == 0

      local = DateTime.shift_zone!(enrollment.next_send_at, ctx.project.timezone)
      assert local.hour >= ctx.sequence.send_window_start
      assert local.hour < ctx.sequence.send_window_end
      assert Date.day_of_week(DateTime.to_date(local)) in ctx.sequence.send_days
    end

    test "refuses a suppressed address", ctx do
      prospect = prospect_fixture(ctx.project)
      Outreach.suppress(prospect.email, "manual")

      assert {:error, :suppressed} = Outreach.enroll_prospect(ctx.sequence, prospect)
    end

    test "refuses a sequence with no steps", ctx do
      empty = sequence_fixture(ctx.project, name: "Empty")
      prospect = prospect_fixture(ctx.project)

      assert {:error, :no_steps} = Outreach.enroll_prospect(empty, prospect)
    end

    test "will not enroll the same prospect twice", ctx do
      prospect = prospect_fixture(ctx.project)

      assert {:ok, _} = Outreach.enroll_prospect(ctx.sequence, prospect)
      assert {:error, changeset} = Outreach.enroll_prospect(ctx.sequence, prospect)
      assert "is already enrolled in this sequence" in errors_on(changeset).sequence_id
    end
  end

  describe "enroll_prospects/2" do
    test "skips who it can't mail rather than failing the whole batch", ctx do
      ok = prospect_fixture(ctx.project)
      blocked = prospect_fixture(ctx.project)
      Outreach.suppress(blocked.email, "manual")

      {:ok, result} = Outreach.enroll_prospects(ctx.sequence, [ok.id, blocked.id])

      assert result == %{enrolled: 1, skipped: 1}
    end
  end

  describe "unsubscribe_prospect/1" do
    test "suppresses globally and stops every sequence they're in", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)

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

      other_sequence = sequence_fixture(other_project)
      step_fixture(other_sequence)
      assert {:error, :suppressed} = Outreach.enroll_prospect(other_sequence, other)
    end
  end

  describe "mark_replied/1" do
    test "stops the drip so a conversation isn't interrupted by a follow-up", ctx do
      prospect = prospect_fixture(ctx.project)
      {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)

      {:ok, prospect} = Outreach.mark_replied(prospect)

      assert prospect.status == "replied"
      assert Repo.reload(enrollment).stopped_reason == "replied"
      # Replying is not opting out — they stay mailable for other projects.
      refute Outreach.suppressed?(prospect.email)
    end
  end

  describe "delete_step/1" do
    test "closes the gap so positions stay a dense run", ctx do
      one = hd(ctx.sequence.steps)
      two = step_fixture(ctx.sequence, %{"subject" => "Two"})
      three = step_fixture(ctx.sequence, %{"subject" => "Three"})

      {:ok, :ok} = Outreach.delete_step(two)

      assert Repo.reload(one).position == 1
      assert Repo.reload(three).position == 2
    end
  end

  describe "activate_sequence/1" do
    test "refuses a sequence with no emails in it", ctx do
      empty = sequence_fixture(ctx.project, name: "Empty")
      assert {:error, :no_steps} = Outreach.activate_sequence(empty)
    end

    test "activates once there's a step", ctx do
      assert {:ok, sequence} = Outreach.activate_sequence(ctx.sequence)
      assert sequence.status == "active"
    end
  end
end
