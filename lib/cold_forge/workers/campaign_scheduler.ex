defmodule ColdForge.Workers.CampaignScheduler do
  @moduledoc """
  Runs every five minutes and queues a send job for each enrollment that has
  come due.

  The scan is the only thing that looks at the clock; individual sends do not
  reschedule themselves. That keeps the daily cap enforceable — it's applied
  here, across the whole campaign, rather than guessed at by each job.
  """

  use Oban.Worker, queue: :scheduler, max_attempts: 3

  import Ecto.Query

  alias ColdForge.Outreach.{Enrollment, Message, Campaign}
  alias ColdForge.Repo
  alias ColdForge.Workers.SendMessage

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    for campaign <- active_campaigns() do
      remaining = remaining_today(campaign)

      if remaining > 0 do
        campaign
        |> due_enrollments(now, remaining)
        |> Enum.each(&queue_send/1)
      end
    end

    :ok
  end

  defp active_campaigns do
    Campaign
    |> join(:inner, [s], p in assoc(s, :project))
    |> where([s, p], s.status == "active" and p.active)
    |> preload(:project)
    |> Repo.all()
  end

  # Enrollments whose prospect has gone cold since scheduling are filtered in
  # SQL, so a stopped campaign can't leak a send through a stale row.
  defp due_enrollments(%Campaign{} = campaign, now, limit) do
    Enrollment
    |> join(:inner, [e], p in assoc(e, :prospect))
    |> where(
      [e, p],
      e.campaign_id == ^campaign.id and e.status == "active" and
        not is_nil(e.next_send_at) and e.next_send_at <= ^now and
        p.status in ["new", "active"]
    )
    |> order_by([e], asc: e.next_send_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How many more sends this campaign may make today, against its `daily_cap`.

  Counted from messages actually sent in the last 24 hours rather than from a
  calendar day, so restarting the app mid-day can't reset the budget.
  """
  def remaining_today(%Campaign{} = campaign) do
    since = DateTime.utc_now() |> DateTime.add(-24, :hour)

    sent =
      from(m in Message,
        join: e in assoc(m, :enrollment),
        where: e.campaign_id == ^campaign.id and m.status == "sent" and m.sent_at >= ^since,
        select: count(m.id)
      )
      |> Repo.one()

    max(campaign.daily_cap - sent, 0)
  end

  # `unique` keeps a slow send from being queued twice by the next scan five
  # minutes later — the job is still in-flight, so a duplicate would double-mail.
  defp queue_send(%Enrollment{} = enrollment) do
    %{enrollment_id: enrollment.id}
    |> SendMessage.new(
      unique: [
        period: 3600,
        fields: [:args, :worker],
        states: [:available, :scheduled, :executing]
      ]
    )
    |> Oban.insert()
  end
end
