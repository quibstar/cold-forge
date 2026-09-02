defmodule ColdForge.Workers.SendMessage do
  @moduledoc """
  Sends the current step for one enrollment, then advances it.

  Re-checks everything at execution time. The scheduler decided this was due;
  between then and now the prospect may have unsubscribed, replied, or been
  suppressed by a bounce on another project.
  """

  use Oban.Worker, queue: :sending, max_attempts: 3

  alias ColdForge.{Outreach, Sending}
  alias ColdForge.Outreach.Enrollment
  alias ColdForge.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"enrollment_id" => enrollment_id}}) do
    case Repo.get(Enrollment, enrollment_id) do
      nil ->
        # The enrollment was deleted while the job sat in the queue. Nothing to
        # do, and nothing wrong — don't retry.
        :ok

      enrollment ->
        send_for(Repo.preload(enrollment, [:prospect, campaign: [:project, :steps]]))
    end
  end

  defp send_for(%Enrollment{status: status}) when status != "active", do: :ok

  defp send_for(%Enrollment{} = enrollment) do
    project = enrollment.campaign.project
    prospect = enrollment.prospect
    step = Enum.find(enrollment.campaign.steps, &(&1.position == enrollment.current_position + 1))

    cond do
      is_nil(step) ->
        # Steps were deleted out from under an in-flight enrollment.
        {:ok, _} = Sending.advance_enrollment(enrollment)
        :ok

      true ->
        case Sending.deliver_step(prospect, step, project,
               enrollment_id: enrollment.id,
               branded: enrollment.campaign.branded,
               question: ColdForge.Survey.email_question(step.survey_id)
             ) do
          {:ok, _message} ->
            {:ok, _} = Sending.advance_enrollment(enrollment)
            :ok

          {:error, reason} when reason in [:suppressed, :prospect_not_mailable] ->
            # Not a failure — the person opted out. Stop the enrollment quietly
            # rather than retrying into a wall three times.
            Outreach.stop_enrollment(enrollment, to_string(reason))
            :ok

          {:error, :project_inactive} ->
            # Leave the enrollment active: reactivating the project should
            # resume the drip rather than require re-enrolling everyone.
            :ok

          {:error, reason} ->
            Logger.error("send failed for enrollment #{enrollment.id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end
end
