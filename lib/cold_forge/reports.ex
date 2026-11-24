defmodule ColdForge.Reports do
  @moduledoc """
  The daily review: how yesterday's drips did, whether each sending address
  looks healthy, who replied wanting to see more, and how an A/B/C opener test
  is going.

  It used to be a scheduled Claude run on a laptop that queried production over
  SSH. It lives here now so it needs nothing but the app: the page at
  `/admin/report` shows it any time, and `ColdForge.Workers.DailyReview` emails
  it every weekday morning and applies the one automatic action, slowing a drip
  whose bounces spike.

  Days are Eastern days. "Yesterday" is the last full sending day: on a Monday
  that's Friday through Sunday.
  """
  import Ecto.Query

  alias ColdForge.Inbox.Reply
  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Campaign, CampaignStep, Enrollment, Message, Project, Prospect}
  alias ColdForge.Repo

  @tz "America/New_York"

  # A drip with at least this many sends in the window, and bounces over the
  # rate or any complaint, gets its daily limits halved.
  @slow_min_sends 20
  @slow_bounce_rate 0.05
  @slow_floor 5

  # Sending-address warnings.
  @address_bounce_rate 0.03
  @address_jump 0.5

  # Opener tests: no winner until every version has this many first emails
  # and this many days have passed since the last of them reached it.
  @test_min_sends 150
  @test_wait_days 5

  # Negative is checked first, so "not interested" never counts as hot.
  @negative ~r/\b(stop|unsubscribe|remove me|take me off|not interested|no thanks|no thank you|f+u+c+k|f\*+k|spam|scam|don'?t (email|contact|message)|leave me alone)\b/i
  @hot ~r/\b(show me|interested|send it|send (me )?(the |a |more )?(video|link|demo|info|details)|call me|give me a call|tell me more|how much|pricing|what does it cost|sounds good|let'?s talk|set up a (call|time|demo)|demo)\b/i
  @inbox_trouble ~r/\b(spam|junk)\b/i

  @variant ~r/\((?<letter>[A-Z]): (?<label>[^)]+)\)\s*$/

  ## The window

  @doc "Today's date in Eastern time."
  def local_today, do: DateTime.now!(@tz) |> DateTime.to_date()

  @doc """
  The last full sending day before `today`: yesterday, or Friday through Sunday
  when `today` is a Monday. Returns the dates and the UTC bounds.
  """
  def window(today \\ local_today()) do
    last = Date.add(today, -1)
    first = if Date.day_of_week(today) == 1, do: Date.add(today, -3), else: last
    %{first: first, last: last, from: utc_start(first), to: utc_start(Date.add(last, 1))}
  end

  @doc """
  The window from `first` through `last`, both Eastern dates, inclusive.
  Swaps them if they're backwards.
  """
  def range(%Date{} = first, %Date{} = last) do
    [first, last] = Enum.sort([first, last], Date)
    %{first: first, last: last, from: utc_start(first), to: utc_start(Date.add(last, 1))}
  end

  defp utc_start(date) do
    date |> DateTime.new!(~T[00:00:00], @tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp local_date(%DateTime{} = dt), do: dt |> DateTime.shift_zone!(@tz) |> DateTime.to_date()

  ## The report

  @doc """
  The morning review: the last sending day before `today`, with the drips
  that the bounce rule would slow.
  """
  def daily(today \\ local_today()) do
    report(window(today), today: today, slow: true)
  end

  @doc """
  The report for any window from `range/2`. Options: `:project_id` to show one
  project, `:slow` to include the bounce-rule list (the morning job's), and
  `:today` for the opener test's clock.

  Drips show if they're active or sent anything in the window, so a drip
  paused since still shows for last month.
  """
  def report(window, opts \\ []) do
    today = Keyword.get(opts, :today, local_today())
    project_id = Keyword.get(opts, :project_id)

    projects =
      Repo.all(from p in Project, where: p.active, order_by: p.name)
      |> Enum.filter(&(is_nil(project_id) or &1.id == project_id))

    campaigns =
      Repo.all(
        from c in Campaign,
          where: c.status != "draft" and c.project_id in ^Enum.map(projects, & &1.id),
          order_by: c.name
      )

    rows =
      campaigns
      |> campaign_rows(window)
      |> Enum.filter(fn r ->
        r.campaign.status == "active" or r.sent + r.bounced + r.replies + r.unsubscribed > 0
      end)

    project_ids = MapSet.new(projects, & &1.id)
    replies = window |> replies() |> Enum.filter(&(&1.project_id in project_ids))
    addresses = addresses(projects, window, replies)
    tests = opener_tests(projects, today)
    slow = if opts[:slow], do: Enum.filter(rows, &slow?/1), else: []

    by_project = Enum.group_by(rows, & &1.campaign.project_id)

    report = %{
      window: window,
      projects:
        projects
        |> Enum.map(&%{project: &1, rows: Map.get(by_project, &1.id, [])})
        |> Enum.sort_by(&{project_rank(&1.project), &1.project.name}),
      replies: replies,
      hot: Enum.filter(replies, &(&1.tone == :hot)),
      addresses: addresses,
      tests: tests,
      slow: slow
    }

    Map.put(report, :status, status(report))
  end

  # ExteriorPro is the priority, so it leads.
  defp project_rank(%Project{name: name}),
    do: if(String.starts_with?(String.downcase(name), "exteriorpro"), do: 0, else: 1)

  defp campaign_rows([], _window), do: []

  defp campaign_rows(campaigns, %{from: from, to: to}) do
    ids = Enum.map(campaigns, & &1.id)

    sent =
      counts(
        from m in Message,
          join: e in Enrollment,
          on: e.id == m.enrollment_id,
          where: e.campaign_id in ^ids and m.sent_at >= ^from and m.sent_at < ^to,
          group_by: e.campaign_id,
          select: {e.campaign_id, count(m.id)}
      )

    failed =
      counts(
        from m in Message,
          join: e in Enrollment,
          on: e.id == m.enrollment_id,
          where:
            e.campaign_id in ^ids and m.status == "failed" and m.failed_at >= ^from and
              m.failed_at < ^to,
          group_by: e.campaign_id,
          select: {e.campaign_id, count(m.id)}
      )

    stops =
      Repo.all(
        from e in Enrollment,
          where:
            e.campaign_id in ^ids and
              e.stopped_reason in ["bounced", "complained", "unsubscribed"] and
              e.updated_at >= ^from and e.updated_at < ^to,
          group_by: [e.campaign_id, e.stopped_reason],
          select: {e.campaign_id, e.stopped_reason, count(e.id)}
      )
      |> Map.new(fn {c, reason, n} -> {{c, reason}, n} end)

    replied =
      counts(
        from r in Reply,
          join: m in Message,
          on: m.id == r.message_id,
          join: e in Enrollment,
          on: e.id == m.enrollment_id,
          where:
            e.campaign_id in ^ids and not r.automated and r.received_at >= ^from and
              r.received_at < ^to,
          group_by: e.campaign_id,
          select: {e.campaign_id, count(r.id)}
      )

    waiting =
      counts(
        from e in Enrollment,
          where: e.campaign_id in ^ids and e.status == "active" and e.current_position == 0,
          group_by: e.campaign_id,
          select: {e.campaign_id, count(e.id)}
      )

    Enum.map(campaigns, fn c ->
      %{
        campaign: c,
        sent: Map.get(sent, c.id, 0),
        failed: Map.get(failed, c.id, 0),
        bounced: Map.get(stops, {c.id, "bounced"}, 0),
        complained: Map.get(stops, {c.id, "complained"}, 0),
        unsubscribed: Map.get(stops, {c.id, "unsubscribed"}, 0),
        replies: Map.get(replied, c.id, 0),
        waiting: Map.get(waiting, c.id, 0)
      }
    end)
  end

  defp counts(query), do: query |> Repo.all() |> Map.new()

  ## Replies

  defp replies(%{from: from, to: to}) do
    Repo.all(
      from r in Reply,
        join: p in Prospect,
        on: p.id == r.prospect_id,
        left_join: m in Message,
        on: m.id == r.message_id,
        left_join: e in Enrollment,
        on: e.id == m.enrollment_id,
        left_join: c in Campaign,
        on: c.id == e.campaign_id,
        where: not r.automated and r.received_at >= ^from and r.received_at < ^to,
        order_by: r.received_at,
        select: %{
          id: r.id,
          body: r.body,
          received_at: r.received_at,
          company: p.company,
          email: p.email,
          project_id: p.project_id,
          campaign: c.name
        }
    )
    |> Enum.map(fn r ->
      r |> Map.put(:first_line, first_line(r.body)) |> Map.put(:tone, tone(r.body))
    end)
  end

  @doc "The first line of a reply with any text on it."
  def first_line(nil), do: ""

  def first_line(body) do
    body
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, 200)
  end

  @doc """
  `:hot` when a reply asks to see it or talk, `:negative` when it says stop or
  worse, `:neutral` otherwise. Keyword matching only, so the page shows the
  text too; a person decides.
  """
  def tone(nil), do: :neutral

  def tone(body) do
    # Only what they wrote: quoted history below would match our own email.
    text = body |> String.split(~r/\R(On .+wrote:|>|-{2,}\s*Original Message)/) |> hd()

    cond do
      Regex.match?(@negative, text) -> :negative
      Regex.match?(@hot, text) -> :hot
      true -> :neutral
    end
  end

  ## Sending addresses

  @doc "The address a project sends from, by domain: hello.furizzma.com."
  def address(%Project{from_email: email}) do
    case String.split(email || "", "@") do
      [_, domain] -> String.downcase(domain)
      _ -> "unknown"
    end
  end

  defp addresses(projects, window, replies) do
    address_of = Map.new(projects, &{&1.id, address(&1)})
    project_ids = Map.keys(address_of)
    # Health checks look at the 7 days (and the two sending days) ending on the
    # window's last day, whatever the window is; totals cover the window.
    since = utc_start(Enum.min([window.first, Date.add(window.last, -13)], Date))
    week_from = utc_start(Date.add(window.last, -6))
    stops_from = Enum.min([window.from, week_from], DateTime)

    daily =
      Repo.all(
        from m in Message,
          where: m.project_id in ^project_ids and m.sent_at >= ^since and m.sent_at < ^window.to,
          group_by: [
            m.project_id,
            fragment("(timezone('America/New_York', timezone('UTC', ?)))::date", m.sent_at)
          ],
          select:
            {m.project_id,
             fragment("(timezone('America/New_York', timezone('UTC', ?)))::date", m.sent_at),
             count(m.id)}
      )

    stops =
      Repo.all(
        from e in Enrollment,
          join: c in Campaign,
          on: c.id == e.campaign_id,
          where:
            c.project_id in ^project_ids and e.stopped_reason in ["bounced", "complained"] and
              e.updated_at >= ^stops_from and e.updated_at < ^window.to,
          select: {c.project_id, e.stopped_reason, e.updated_at}
      )

    trouble_replies =
      Enum.filter(replies, &Regex.match?(@inbox_trouble, &1.body || ""))

    projects
    |> Enum.group_by(&address_of[&1.id])
    |> Enum.map(fn {addr, ps} ->
      ids = MapSet.new(ps, & &1.id)

      by_day =
        daily
        |> Enum.filter(fn {pid, _d, _n} -> pid in ids end)
        |> Enum.reduce(%{}, fn {_pid, d, n}, acc -> Map.update(acc, d, n, &(&1 + n)) end)

      in_window = fn d -> Date.compare(d, window.first) != :lt end

      sent =
        by_day
        |> Enum.filter(fn {d, _} -> in_window.(d) end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      week_sent =
        by_day
        |> Enum.filter(fn {d, _} -> Date.diff(window.last, d) < 7 end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      my_stops = Enum.filter(stops, fn {pid, _, _} -> pid in ids end)

      count_stops = fn reason, pred ->
        Enum.count(my_stops, fn {_, r, at} -> r == reason and pred.(at) end)
      end

      in_win = fn at -> DateTime.compare(at, window.from) != :lt end
      in_week = fn at -> DateTime.compare(at, week_from) != :lt end

      week_bounced = count_stops.("bounced", in_week)
      bounced = count_stops.("bounced", in_win)
      complaints = count_stops.("complained", in_win)
      week_complaints = count_stops.("complained", in_week)

      days = by_day |> Enum.filter(fn {_d, n} -> n > 0 end) |> Enum.sort_by(&elem(&1, 0), Date)

      # Against the median of the previous five sending days, so a light
      # Saturday doesn't make Monday look like a spike.
      jump =
        case Enum.reverse(days) do
          [{d1, n1} | earlier] when earlier != [] ->
            base = earlier |> Enum.take(5) |> Enum.map(&elem(&1, 1)) |> median()
            if in_window.(d1) and base > 0, do: (n1 - base) / base, else: nil

          _ ->
            nil
        end

      week_rate = if week_sent > 0, do: week_bounced / week_sent, else: 0.0

      trouble =
        Enum.filter(trouble_replies, fn r -> address_of[r.project_id] == addr end)

      warnings =
        Enum.reject(
          [
            week_rate > @address_bounce_rate &&
              "7-day bounce rate is #{pct(week_rate)}, over #{pct(@address_bounce_rate)}",
            complaints > 0 && "#{complaints} spam complaint(s)",
            jump && jump > @address_jump &&
              "daily sends jumped #{pct(jump)} over a typical recent day (median of the last 5 sending days)",
            trouble != [] && "#{length(trouble)} reply(ies) mention spam or junk folders"
          ],
          &(&1 in [nil, false])
        )

      %{
        address: addr,
        projects: Enum.map(ps, & &1.name),
        sent: sent,
        bounced: bounced,
        rate: if(sent > 0, do: bounced / sent, else: 0.0),
        complaints: complaints,
        week_sent: week_sent,
        week_bounced: week_bounced,
        week_complaints: week_complaints,
        week_rate: week_rate,
        # One day: the trend leading up to it. A range: the range.
        days:
          if(window.first == window.last,
            do: Enum.take(days, -8),
            else: Enum.filter(days, fn {d, _} -> in_window.(d) end)
          ),
        jump: jump,
        warnings: warnings
      }
    end)
    |> Enum.sort_by(& &1.address)
  end

  defp median(ns) do
    sorted = Enum.sort(ns)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  @doc false
  def pct(rate), do: "#{Float.round(rate * 100, 1)}%"

  ## Opener tests

  @doc """
  Campaigns named like "Texas exteriors (A: texts & paper)" are versions of one
  opener test, grouped per project by their letter across markets, so Texas A
  and Florida A count together.

  Counting starts on the day the last version sent its first email, so a
  version that ran alone before the test began isn't credited with a head start.
  """
  def opener_tests(projects, today \\ local_today()) do
    project_ids = Enum.map(projects, & &1.id)

    campaigns =
      Repo.all(
        from c in Campaign,
          where: c.project_id in ^project_ids and c.status in ["active", "paused"]
      )
      |> Enum.flat_map(fn c ->
        case Regex.named_captures(@variant, c.name) do
          %{"letter" => l, "label" => label} -> [{c, l, label}]
          nil -> []
        end
      end)

    campaigns
    |> Enum.group_by(fn {c, _, _} -> c.project_id end)
    |> Enum.filter(fn {_pid, cs} ->
      cs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {pid, cs} -> opener_test(Enum.find(projects, &(&1.id == pid)), cs, today) end)
  end

  defp opener_test(project, cs, today) do
    ids = Enum.map(cs, fn {c, _, _} -> c.id end)
    letter_of = Map.new(cs, fn {c, l, _} -> {c.id, l} end)

    first_step =
      Repo.all(
        from s in CampaignStep,
          where: s.campaign_id in ^ids,
          group_by: s.campaign_id,
          select: {s.campaign_id, min(s.position)}
      )
      |> Map.new()

    sends =
      Repo.all(
        from m in Message,
          join: e in Enrollment,
          on: e.id == m.enrollment_id,
          join: s in CampaignStep,
          on: s.id == m.campaign_step_id,
          where: e.campaign_id in ^ids and not is_nil(m.sent_at),
          select: {e.campaign_id, s.position, s.subject, m.subject, m.prospect_id, m.sent_at}
      )
      # Only the current opener: a first email sent under an older subject
      # was a different test.
      |> Enum.filter(fn {cid, pos, template, subject, _, _} ->
        pos == first_step[cid] and subject_matches?(template, subject)
      end)
      |> Enum.map(fn {cid, _, _, _, pid, at} -> {letter_of[cid], pid, at} end)

    starts =
      sends
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
      |> Map.new(fn {l, ats} -> {l, Enum.min(ats, DateTime)} end)

    start = if starts == %{}, do: nil, else: starts |> Map.values() |> Enum.max(DateTime)

    counted =
      if start do
        start_day = local_date(start)
        Enum.filter(sends, fn {_, _, at} -> Date.compare(local_date(at), start_day) != :lt end)
      else
        []
      end

    prospects =
      counted
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {l, ps} -> {l, Enum.uniq(ps)} end)

    all_prospects = prospects |> Map.values() |> List.flatten()

    reply_tones =
      if start && all_prospects != [] do
        Repo.all(
          from r in Reply,
            where:
              r.prospect_id in ^all_prospects and not r.automated and r.received_at >= ^start,
            select: {r.prospect_id, r.body}
        )
        |> Enum.group_by(&elem(&1, 0), &tone(elem(&1, 1)))
      else
        %{}
      end

    unsubs =
      Repo.all(
        from e in Enrollment,
          where: e.campaign_id in ^ids and e.stopped_reason == "unsubscribed",
          select: {e.campaign_id, e.prospect_id}
      )

    labels = cs |> Enum.map(fn {_, l, label} -> {l, label} end) |> Map.new()

    variants =
      labels
      |> Enum.sort()
      |> Enum.map(fn {l, label} ->
        ps = Map.get(prospects, l, [])
        pset = MapSet.new(ps)
        tones = ps |> Enum.flat_map(&Map.get(reply_tones, &1, [])) |> Enum.frequencies()
        replied = Enum.count(ps, &Map.has_key?(reply_tones, &1))

        times =
          counted
          |> Enum.filter(&(elem(&1, 0) == l))
          |> Enum.map(&elem(&1, 2))
          |> Enum.sort(DateTime)

        %{
          letter: l,
          label: label,
          sends: length(ps),
          replied: replied,
          positive: Map.get(tones, :hot, 0),
          negative: Map.get(tones, :negative, 0),
          unsubscribed:
            Enum.count(unsubs, fn {cid, pid} -> letter_of[cid] == l and pid in pset end),
          reached_min_on: times |> Enum.at(@test_min_sends - 1) |> then(&(&1 && local_date(&1)))
        }
      end)

    %{
      project: project,
      start: start && local_date(start),
      variants: variants,
      verdict: verdict(variants, today)
    }
  end

  @doc """
  Whether a sent subject came from a step's subject template, merge fields
  and all: "how Acme tracks jobs" matches "how {{company}} tracks jobs".
  """
  def subject_matches?(template, subject) when is_binary(template) and is_binary(subject) do
    pattern =
      ~r/\{\{[^}]*\}\}/
      |> Regex.split(String.trim(template))
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("^" <> pattern <> "$", "is"), String.trim(subject))
  end

  def subject_matches?(_template, _subject), do: false

  defp verdict(variants, today) do
    reached = Enum.map(variants, & &1.reached_min_on)

    cond do
      Enum.any?(reached, &is_nil/1) ->
        short =
          Enum.filter(variants, &is_nil(&1.reached_min_on)) |> Enum.map_join(", ", & &1.letter)

        "Too early to call: #{short} still under #{@test_min_sends} first emails."

      (days = Date.diff(today, Enum.max(reached, Date))) < @test_wait_days ->
        "Too early to call: every version has #{@test_min_sends}+ sends; waiting #{@test_wait_days - days} more day(s) for replies."

      true ->
        lead =
          Enum.max_by(variants, fn v ->
            {v.positive / max(v.sends, 1), -v.negative / max(v.sends, 1)}
          end)

        "#{lead.letter} (#{lead.label}) leads with #{lead.positive} positive repl(ies) from #{lead.sends} sends. Consider moving the rest of the list to it; that's your call."
    end
  end

  ## Slowing a drip

  defp slow?(row) do
    row.sent >= @slow_min_sends and
      (row.bounced / row.sent > @slow_bounce_rate or row.complained > 0)
  end

  @doc """
  Halves a campaign's starting and ceiling daily limits, never below
  #{@slow_floor}. Returns a sentence saying what changed.
  """
  def slow_campaign(%Campaign{} = campaign, reason) do
    half = fn
      nil -> nil
      n -> max(div(n, 2), @slow_floor)
    end

    attrs = %{
      "daily_cap" => half.(campaign.daily_cap),
      "max_daily_cap" => half.(campaign.max_daily_cap)
    }

    with {:ok, updated} <- Outreach.update_campaign(campaign, attrs) do
      {:ok,
       "Slowed #{campaign.name} (#{reason}): #{campaign.daily_cap}→#{updated.daily_cap} a day, ramping to #{updated.max_daily_cap || "no ceiling"} (was #{campaign.max_daily_cap || "no ceiling"})."}
    end
  end

  @doc false
  def slow_reason(row) do
    if row.complained > 0,
      do: "#{row.complained} spam complaint(s)",
      else: "#{row.bounced} of #{row.sent} bounced, #{pct(row.bounced / row.sent)}"
  end

  ## Status line

  defp status(report) do
    warnings = Enum.flat_map(report.addresses, & &1.warnings)

    cond do
      report.hot != [] ->
        "#{length(report.hot)} interested repl(ies) need an answer"

      report.slow != [] or warnings != [] ->
        "#{length(report.slow) + length(warnings)} thing(s) to look at"

      true ->
        sent = report.projects |> Enum.flat_map(& &1.rows) |> Enum.map(& &1.sent) |> Enum.sum()
        "All normal, #{sent} sent"
    end
  end

  @doc "\"Mon Nov 23\" or \"Fri Nov 20 – Sun Nov 22\"."
  def window_label(%{first: same, last: same}), do: Calendar.strftime(same, "%a %b %-d")

  def window_label(%{first: first, last: last}),
    do: Calendar.strftime(first, "%a %b %-d") <> " – " <> Calendar.strftime(last, "%a %b %-d")
end
