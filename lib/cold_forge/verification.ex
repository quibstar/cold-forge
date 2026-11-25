defmodule ColdForge.Verification do
  @moduledoc """
  Whether an address is worth sending to, asked of Reoon before it can bounce.

  Two ways in:

    * `check/1`, one address, from the contact finder as it finds them
      (`ColdForge.Sourcing.record_found/3`).
    * `start_sweep/1`, everyone in a project's live drips not yet checked, as
      one bulk task that `ColdForge.Workers.VerifySweep` waits out and applies.

  What gets dropped is decided here, once. Tested against 44 addresses that had
  already bounced: Reoon called 26 `invalid`, and those are the clear case.
  `catch_all` and `unknown` are a mail server declining to say, not a dead
  mailbox — most catch-all business domains are real — so they are sent to.
  """
  require Logger
  import Ecto.Query

  alias ColdForge.{Outreach, Repo}
  alias ColdForge.Outreach.{Enrollment, Prospect}
  alias ColdForge.Verification.Reoon

  @undeliverable ~w(invalid disabled spamtrap disposable)

  @doc "The verdicts that keep an address off a send list."
  def undeliverable, do: @undeliverable

  def undeliverable?(verdict), do: verdict in @undeliverable

  @doc """
  Checks one address. `{:ok, verdict}`, or `:unchecked` when the check can't
  run (no key configured, Reoon down or slow) — never a reason to drop one.
  """
  @spec check(String.t() | nil) :: {:ok, String.t()} | :unchecked
  def check(email) when is_binary(email) and email != "" do
    if Reoon.configured?() do
      case Reoon.verify(email) do
        {:ok, %{status: verdict}} ->
          {:ok, verdict}

        {:error, reason} ->
          Logger.warning("email verification skipped: #{inspect(reason)}")
          :unchecked
      end
    else
      :unchecked
    end
  end

  def check(_email), do: :unchecked

  ## Sweeping a project's drips

  @doc """
  The prospects a sweep would check: in an active enrollment of one of the
  project's active campaigns, with an address, and not checked yet.
  """
  def sweep_candidates(project_id) do
    Prospect
    |> join(:inner, [p], e in Enrollment, on: e.prospect_id == p.id and e.status == "active")
    |> join(:inner, [_p, e], c in assoc(e, :campaign))
    |> where([p, _e, c], c.project_id == ^project_id and c.status == "active")
    |> where([p], not is_nil(p.email) and p.email != "" and is_nil(p.email_checked_at))
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Sends a project's unchecked drip contacts to Reoon as one bulk task and
  queues the job that waits for it. `{:ok, %{task_id: ..., count: n}}`, or
  `{:ok, :nothing_to_check}`.
  """
  def start_sweep(project_id) do
    emails =
      project_id |> sweep_candidates() |> Enum.map(&String.downcase(&1.email)) |> Enum.uniq()

    with [_ | _] <- emails,
         {:ok, task_id} <- Reoon.create_bulk(emails, "cold-forge sweep") do
      %{task_id: task_id, project_id: project_id}
      |> ColdForge.Workers.VerifySweep.new()
      |> Oban.insert()

      {:ok, %{task_id: task_id, count: length(emails)}}
    else
      [] -> {:ok, :nothing_to_check}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies a finished task's verdicts to the project's unchecked drip contacts.

  Every checked address gets its verdict recorded. An undeliverable one also
  has its live enrollments stopped (`undeliverable`, which reports don't count
  as a bounce) and goes on the do-not-contact list, so it can't be enrolled
  again. Returns the count per verdict.
  """
  def apply_results(project_id, %{} = verdicts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    project_id
    |> sweep_candidates()
    |> Enum.reduce(%{}, fn prospect, counts ->
      case Map.fetch(verdicts, String.downcase(prospect.email)) do
        {:ok, verdict} ->
          record(prospect, verdict, now)
          Map.update(counts, verdict, 1, &(&1 + 1))

        :error ->
          counts
      end
    end)
  end

  defp record(%Prospect{} = prospect, verdict, now) do
    Repo.transaction(fn ->
      {:ok, _} =
        prospect
        |> Ecto.Changeset.change(email_verdict: verdict, email_checked_at: now)
        |> Repo.update()

      if undeliverable?(verdict) do
        Enrollment
        |> where([e], e.prospect_id == ^prospect.id and e.status == "active")
        |> Repo.all()
        |> Enum.each(&Outreach.stop_enrollment(&1, "undeliverable"))

        Outreach.suppress(prospect.email, "manual", %{
          project_id: prospect.project_id,
          notes: "Email verification (Reoon): #{verdict}"
        })
      end
    end)
  end
end
