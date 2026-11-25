defmodule ColdForge.Workers.VerifySweep do
  @moduledoc """
  Waits out a Reoon bulk task started by `ColdForge.Verification.start_sweep/1`
  and applies its verdicts.

  Snoozes a minute at a time while Reoon works. A sweep of a few thousand
  addresses takes Reoon a while; the cap below gives it most of a day.
  """
  use Oban.Worker, queue: :search, max_attempts: 5

  require Logger

  alias ColdForge.Verification
  alias ColdForge.Verification.Reoon

  @poll_seconds 60
  @max_polls 60 * 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id, "project_id" => project_id}} = job) do
    case Reoon.bulk_result(task_id) do
      {:ok, {:running, _percent}} ->
        if polls(job) >= @max_polls,
          do: {:cancel, :reoon_task_never_finished},
          else: {:snooze, @poll_seconds}

      {:ok, {:done, verdicts}} ->
        counts = Verification.apply_results(project_id, verdicts)
        Logger.info("email verification sweep #{task_id} applied: #{inspect(counts)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Oban counts each snooze as an attempt (and raises max_attempts to match),
  # so the attempt number is how many times this has looked.
  defp polls(%Oban.Job{attempt: attempt}), do: attempt
end
