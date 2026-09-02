defmodule ColdForge.Workers.SendMessageTest do
  @moduledoc """
  Sending one step and moving the enrollment on. The re-checks matter: the
  scheduler queued this job, but the world may have changed since.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Workers.SendMessage

  setup do
    project = project_fixture()
    sequence = sequence_fixture(project)
    step_fixture(sequence, %{"subject" => "One"})
    step_fixture(sequence, %{"subject" => "Two", "delay_days" => 3})
    {:ok, _} = Outreach.activate_sequence(Outreach.get_sequence!(sequence.id))

    sequence = Outreach.get_sequence!(sequence.id)
    prospect = prospect_fixture(project)
    {:ok, enrollment} = Outreach.enroll_prospect(sequence, prospect)

    %{project: project, sequence: sequence, prospect: prospect, enrollment: enrollment}
  end

  test "sends the current step and advances to the next", ctx do
    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})

    [message] = Outreach.list_messages(ctx.project.id)
    assert message.subject == "One"
    assert message.status == "sent"

    enrollment = Repo.reload(ctx.enrollment)
    assert enrollment.status == "active"
    assert enrollment.current_position == 1
    # Step two waits three days, so the next send can't be sooner than that.
    assert DateTime.diff(enrollment.next_send_at, DateTime.utc_now(), :day) >= 2
  end

  test "completes the enrollment after the last step", ctx do
    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})
    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})

    enrollment = Repo.reload(ctx.enrollment)
    assert enrollment.status == "completed"
    assert enrollment.completed_at
    assert enrollment.next_send_at == nil
    assert length(Outreach.list_messages(ctx.project.id)) == 2
  end

  test "stops quietly when the prospect unsubscribed after queueing", ctx do
    {:ok, _} = Outreach.unsubscribe_prospect(ctx.prospect)

    # Not a job failure — the person opted out. Retrying three times into a
    # wall would just fill the dead queue.
    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})
    assert Outreach.list_messages(ctx.project.id) == []
  end

  test "leaves the enrollment resumable when the project is paused", ctx do
    {:ok, _} = Outreach.update_project(ctx.project, %{active: false})

    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})

    # Still active: reactivating the project should resume the drip rather
    # than require re-enrolling everyone.
    assert Repo.reload(ctx.enrollment).status == "active"
    assert Outreach.list_messages(ctx.project.id) == []
  end

  test "does nothing for an enrollment deleted while queued", ctx do
    Repo.delete!(ctx.enrollment)
    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})
  end

  test "does nothing for a stopped enrollment", ctx do
    {:ok, _} = Outreach.stop_enrollment(ctx.enrollment)

    assert :ok = perform_job(SendMessage, %{enrollment_id: ctx.enrollment.id})
    assert Outreach.list_messages(ctx.project.id) == []
  end
end
