defmodule ColdForge.Workers.SequenceSchedulerTest do
  @moduledoc """
  The scheduler decides who gets mailed. Its job is as much about *not* sending
  as sending, so most of these assert something didn't happen.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Workers.{SendMessage, SequenceScheduler}

  setup do
    project = project_fixture()
    sequence = sequence_fixture(project)
    step_fixture(sequence)
    {:ok, sequence} = Outreach.activate_sequence(Outreach.get_sequence!(sequence.id))
    %{project: project, sequence: Outreach.get_sequence!(sequence.id)}
  end

  # Enrollments are scheduled into the send window, which is usually in the
  # future. Backdating is how a test says "this one has come due".
  defp make_due(enrollment) do
    enrollment
    |> Ecto.Changeset.change(
      next_send_at: DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  test "queues a send for an enrollment that has come due", ctx do
    prospect = prospect_fixture(ctx.project)
    {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)
    make_due(enrollment)

    assert :ok = perform_job(SequenceScheduler, %{})
    assert_enqueued(worker: SendMessage, args: %{enrollment_id: enrollment.id})
  end

  test "leaves an enrollment alone until its send time", ctx do
    prospect = prospect_fixture(ctx.project)
    {:ok, _enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)

    assert :ok = perform_job(SequenceScheduler, %{})
    refute_enqueued(worker: SendMessage)
  end

  test "ignores a paused sequence", ctx do
    prospect = prospect_fixture(ctx.project)
    {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)
    make_due(enrollment)
    {:ok, _} = Outreach.pause_sequence(ctx.sequence)

    assert :ok = perform_job(SequenceScheduler, %{})
    refute_enqueued(worker: SendMessage)
  end

  test "ignores an inactive project", ctx do
    prospect = prospect_fixture(ctx.project)
    {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)
    make_due(enrollment)
    {:ok, _} = Outreach.update_project(ctx.project, %{active: false})

    assert :ok = perform_job(SequenceScheduler, %{})
    refute_enqueued(worker: SendMessage)
  end

  test "skips a prospect who unsubscribed after being scheduled", ctx do
    prospect = prospect_fixture(ctx.project)
    {:ok, enrollment} = Outreach.enroll_prospect(ctx.sequence, prospect)
    make_due(enrollment)
    {:ok, _} = Outreach.unsubscribe_prospect(prospect)

    assert :ok = perform_job(SequenceScheduler, %{})
    refute_enqueued(worker: SendMessage)
  end

  test "respects the daily cap", ctx do
    {:ok, sequence} = Outreach.update_sequence(ctx.sequence, %{daily_cap: 2})
    sequence = Outreach.get_sequence!(sequence.id)

    for _ <- 1..4 do
      prospect = prospect_fixture(ctx.project)
      {:ok, enrollment} = Outreach.enroll_prospect(sequence, prospect)
      make_due(enrollment)
    end

    assert :ok = perform_job(SequenceScheduler, %{})
    assert length(all_enqueued(worker: SendMessage)) == 2
  end

  test "remaining_today/1 counts against sends in the last 24 hours", ctx do
    {:ok, sequence} = Outreach.update_sequence(ctx.sequence, %{daily_cap: 5})
    assert SequenceScheduler.remaining_today(sequence) == 5
  end
end
