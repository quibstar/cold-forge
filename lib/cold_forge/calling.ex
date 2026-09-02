defmodule ColdForge.Calling do
  @moduledoc """
  Working a prospect list by phone.

  This exists because the segment ExteriorPro sells to does not read email.
  Six real West Michigan roofing companies published one address between them;
  they all publish a phone number. The email machinery is still here and still
  right — it is just the weaker channel for an owner-operator who is on a roof.

  Two rules cross the channel boundary, and both are about not being the kind
  of outreach people hate:

    * Asking not to be called stops the email too. Someone who says "stop
      contacting me" has not made a channel-specific request, and answering it
      by switching channels is exactly the behaviour that earns spam reports.

    * Actually speaking to someone stops their campaign. Following a
      conversation with a cold sequence reads as a machine that was not
      listening.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Calling.Call
  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect
  alias ColdForge.Repo

  # Day 1, 3, 6, 9, 14 — most sales happen after the fifth touch and most
  # people stop at the second. The gaps widen so persistence does not tip into
  # nuisance.
  @cadence [2, 3, 3, 5]

  @doc """
  Who to call, soonest first.

  Never called comes before overdue, because a first attempt is worth more than
  a fifth. Anyone who asked not to be called, replied, unsubscribed or bounced
  is excluded — the queue is the only place that decides who gets dialled, so
  the filtering belongs here rather than in the caller's head.
  """
  def queue(project_id, opts \\ []) do
    limit = opts[:limit] || 50
    now = DateTime.utc_now()

    Prospect
    |> where([p], p.project_id == ^project_id)
    |> where([p], not p.do_not_call)
    |> where([p], p.status in ["new", "active"])
    |> where([p], not is_nil(p.phone) and p.phone != "")
    |> where([p], is_nil(p.next_call_at) or p.next_call_at <= ^now)
    |> order_by([p], asc_nulls_first: p.next_call_at, asc: p.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Everyone with a call scheduled for later, so the day ahead is visible."
  def scheduled(project_id, opts \\ []) do
    now = DateTime.utc_now()

    Prospect
    |> where([p], p.project_id == ^project_id)
    |> where([p], not p.do_not_call and not is_nil(p.next_call_at) and p.next_call_at > ^now)
    |> order_by([p], asc: p.next_call_at)
    |> limit(^(opts[:limit] || 50))
    |> Repo.all()
  end

  def list_calls(prospect_id) do
    Call
    |> where([c], c.prospect_id == ^prospect_id)
    |> order_by([c], desc: c.called_at)
    |> Repo.all()
  end

  def recent_calls(project_id, limit \\ 25) do
    from(c in Call,
      join: p in assoc(c, :prospect),
      where: p.project_id == ^project_id,
      order_by: [desc: c.called_at],
      limit: ^limit,
      preload: [prospect: p]
    )
    |> Repo.all()
  end

  @doc """
  Records an attempt and works out what happens next.

  `attrs` needs an `outcome` and may carry `notes` and `voicemail_script`.
  Everything else — when to call again, whether to stop, what it means for the
  email side — is decided here, so an outcome always has the same consequences
  however it was logged.
  """
  def log_call(%Prospect{} = prospect, attrs) do
    outcome = attrs["outcome"] || attrs[:outcome]
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attempts = prospect.call_attempts + 1
    next_at = next_call_at(outcome, attempts, now)

    Repo.transaction(fn ->
      call =
        %Call{}
        |> Call.changeset(%{
          prospect_id: prospect.id,
          outcome: outcome,
          notes: attrs["notes"] || attrs[:notes],
          voicemail_script: parse_script(attrs["voicemail_script"] || attrs[:voicemail_script]),
          called_at: now,
          next_call_at: next_at
        })
        |> Repo.insert!()

      prospect
      |> Ecto.Changeset.change(
        call_attempts: attempts,
        last_called_at: now,
        next_call_at: next_at,
        do_not_call: prospect.do_not_call or outcome == "do_not_call"
      )
      |> Repo.update!()

      apply_side_effects(outcome, prospect)

      call
    end)
  end

  # A conversation is engagement, so the cold sequence stops — the same rule a
  # reply or a survey answer follows.
  defp apply_side_effects(outcome, prospect) when outcome in ["connected", "interested"] do
    Outreach.mark_replied(prospect)
  end

  # "Stop contacting me" is not a request about telephones. Emailing someone who
  # just said that is how outreach earns its reputation.
  defp apply_side_effects("do_not_call", prospect) do
    Outreach.unsubscribe_prospect(prospect)
  end

  # A wrong number says nothing about whether the email address is good.
  defp apply_side_effects(_outcome, _prospect), do: :ok

  @doc """
  When to try again, or `nil` when there is no point.

  The gaps widen with each attempt. A fifth call the day after the fourth is
  not persistence, it is harassment, and it is the thing that gets a number
  blocked.
  """
  def next_call_at(outcome, attempts, from \\ nil) do
    from = from || DateTime.utc_now() |> DateTime.truncate(:second)

    cond do
      Call.closing?(outcome) ->
        nil

      outcome in ["connected", "interested"] ->
        # A conversation sets its own next step; the queue should not guess one.
        nil

      outcome == "not_now" ->
        DateTime.add(from, 30, :day)

      true ->
        case Enum.at(@cadence, attempts - 1) do
          nil -> nil
          days -> DateTime.add(from, days, :day)
        end
    end
  end

  @doc """
  Which voicemail script to leave next, given how many have already been left.

  Returns `nil` once the fourth — the breakup — has gone, because there is no
  fifth message that helps.
  """
  def next_script(prospect_id) do
    left =
      Call
      |> where([c], c.prospect_id == ^prospect_id and not is_nil(c.voicemail_script))
      |> select([c], max(c.voicemail_script))
      |> Repo.one()

    case left do
      nil -> 1
      n when n < 4 -> n + 1
      _ -> nil
    end
  end

  @doc "Headline numbers for the calling screen."
  def stats(project_id) do
    counts =
      from(c in Call,
        join: p in assoc(c, :prospect),
        where: p.project_id == ^project_id,
        group_by: c.outcome,
        select: {c.outcome, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      calls: counts |> Map.values() |> Enum.sum(),
      conversations: Map.get(counts, "connected", 0) + Map.get(counts, "interested", 0),
      interested: Map.get(counts, "interested", 0),
      voicemails: Map.get(counts, "voicemail", 0),
      by_outcome: counts
    }
  end

  defp parse_script(nil), do: nil
  defp parse_script(""), do: nil
  defp parse_script(n) when is_integer(n), do: n
  defp parse_script(n) when is_binary(n), do: String.to_integer(n)
end
