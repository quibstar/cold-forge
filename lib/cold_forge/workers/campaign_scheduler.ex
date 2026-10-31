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
    # Follow-ups first: a big enrollment queues hundreds of first emails that
    # are all overdue, and oldest-first would hold every follow-up behind them
    # until the backlog drained.
    |> order_by([e], desc: e.current_position, asc: e.next_send_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  How many more sends this campaign may make today, against `cap_today/1`.

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

    max(cap_today(campaign) - sent, 0)
  end

  # Below this many sends a bounce rate is noise, not a signal.
  @bounce_sample 20
  @bounce_limit 0.05

  @doc """
  Today's cap: `daily_cap` plus `ramp_per_day` for each earlier day the
  campaign actually sent on, stopping at `max_daily_cap`.

  Counting sending days rather than calendar days means a weekend, a pause or
  an empty queue doesn't count as warm-up the domain never got. And while the
  last week's bounce rate is over 5% the cap drops back to where it started:
  SES reviews accounts at that rate, and sending more into a dirty list is how
  one gets suspended.
  """
  def cap_today(%Campaign{ramp_per_day: ramp} = campaign) when is_integer(ramp) and ramp > 0 do
    if bouncing?(campaign) do
      campaign.daily_cap
    else
      min(campaign.daily_cap + ramp * sending_days(campaign), campaign.max_daily_cap)
    end
  end

  def cap_today(%Campaign{} = campaign), do: campaign.daily_cap

  defp sending_days(campaign) do
    today = Date.utc_today()

    from(m in Message,
      join: e in assoc(m, :enrollment),
      where:
        e.campaign_id == ^campaign.id and m.status == "sent" and
          fragment("?::date", m.sent_at) < ^today,
      select: fragment("count(DISTINCT ?::date)", m.sent_at)
    )
    |> Repo.one()
  end

  defp bouncing?(campaign) do
    since = DateTime.utc_now() |> DateTime.add(-7, :day)

    {sent, bounced} =
      from(m in Message,
        join: e in assoc(m, :enrollment),
        join: p in assoc(e, :prospect),
        where: e.campaign_id == ^campaign.id and m.status == "sent" and m.sent_at >= ^since,
        select: {count(m.id), count(p.bounced_at)}
      )
      |> Repo.one()

    sent >= @bounce_sample and bounced / sent > @bounce_limit
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
