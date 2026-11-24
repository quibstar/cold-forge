defmodule ColdForge.ReportsTest do
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures
  import Swoosh.TestAssertions

  alias ColdForge.Inbox.Reply
  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Enrollment, Message}
  alias ColdForge.Reports
  alias ColdForge.Workers.{DailyReportEmail, DailyReview}

  describe "window/1" do
    test "a Monday covers Friday through Sunday" do
      w = Reports.window(~D[2026-11-23])
      assert w.first == ~D[2026-11-20]
      assert w.last == ~D[2026-11-22]
      # Midnight Eastern, in UTC.
      assert w.from == ~U[2026-11-20 05:00:00Z]
      assert w.to == ~U[2026-11-23 05:00:00Z]
    end

    test "any other day covers yesterday" do
      w = Reports.window(~D[2026-11-25])
      assert {w.first, w.last} == {~D[2026-11-24], ~D[2026-11-24]}
    end
  end

  describe "tone/1" do
    test "asks to see it or talk" do
      assert Reports.tone("Sure, show me how it works") == :hot
      assert Reports.tone("How much is it?") == :hot
      assert Reports.tone("Call me tomorrow") == :hot
    end

    test "stop and worse win over hot words" do
      assert Reports.tone("Not interested") == :negative
      assert Reports.tone("Please remove me") == :negative
      assert Reports.tone("Fuck off") == :negative
    end

    test "only what they wrote, not the quoted email below" do
      body = "Thanks, we're set.\n\nOn Mon, Nov 23, Kris wrote:\n> want me to show me the demo?"
      assert Reports.tone(body) == :neutral
    end

    test "first_line skips blank lines" do
      assert Reports.first_line("\r\n  \r\nFuck off\r\n\r\nSent from my iPhone") == "Fuck off"
    end
  end

  defp setup_drip(name \\ "Texas exteriors", attrs \\ %{}) do
    project = project_fixture(%{forward_replies_to: "owner@example.com"})

    campaign =
      campaign_fixture(
        project,
        Map.merge(%{name: name, daily_cap: 12, max_daily_cap: 37, ramp_per_day: 1}, attrs)
      )

    step_fixture(campaign, %{"subject" => "One"})
    {:ok, campaign} = Outreach.activate_campaign(Outreach.get_campaign!(campaign.id))
    step = hd(Outreach.get_campaign!(campaign.id).steps)
    %{project: project, campaign: campaign, step: step}
  end

  defp send!(%{project: project, campaign: campaign, step: step}, at, opts \\ []) do
    prospect = prospect_fixture(project, %{company: Keyword.get(opts, :company, "Acme Roofing")})

    enrollment =
      Repo.insert!(%Enrollment{
        campaign_id: campaign.id,
        prospect_id: prospect.id,
        status: if(opts[:stopped], do: "stopped", else: "active"),
        stopped_reason: opts[:stopped],
        current_position: 1,
        updated_at: at,
        inserted_at: at
      })

    message =
      Repo.insert!(%Message{
        project_id: project.id,
        prospect_id: prospect.id,
        enrollment_id: enrollment.id,
        campaign_step_id: step.id,
        subject: step.subject,
        body: "hi",
        open_token: Ecto.UUID.generate(),
        status: "sent",
        sent_at: at
      })

    if reply = opts[:reply] do
      Repo.insert!(%Reply{
        prospect_id: prospect.id,
        message_id: message.id,
        from_email: prospect.email,
        subject: "Re: One",
        matched_by: "exact",
        body: reply,
        received_at: DateTime.add(at, 3600)
      })
    end

    prospect
  end

  defp yesterday, do: DateTime.add(Reports.window().from, 4 * 3600) |> DateTime.truncate(:second)

  test "counts the last sending day and leaves out the day before" do
    drip = setup_drip()
    for _ <- 1..3, do: send!(drip, yesterday())
    send!(drip, DateTime.add(Reports.window().from, -3600) |> DateTime.truncate(:second))
    send!(drip, yesterday(), stopped: "bounced")
    send!(drip, yesterday(), stopped: "unsubscribed", reply: "Not interested")

    report = Reports.daily()
    [%{rows: [row]}] = Enum.filter(report.projects, &(&1.project.id == drip.project.id))

    assert row.sent == 5
    assert row.bounced == 1
    assert row.unsubscribed == 1
    assert row.replies == 1

    assert [%{tone: :negative, first_line: "Not interested"}] =
             Enum.filter(report.replies, &(&1.project_id == drip.project.id))
  end

  test "an interested reply leads the status" do
    drip = setup_drip()
    send!(drip, yesterday(), reply: "Yes, send me the video", company: "Hot Siding Co")

    report = Reports.daily()
    assert [%{company: "Hot Siding Co"}] = report.hot
    assert report.status =~ "interested"
  end

  test "the morning run halves a drip whose bounces spiked and emails what it did" do
    drip = setup_drip("Permit contractors - Texas")
    for _ <- 1..22, do: send!(drip, yesterday())
    for _ <- 1..3, do: send!(drip, yesterday(), stopped: "bounced")

    assert :ok = perform_job(DailyReview, %{})

    campaign = Outreach.get_campaign!(drip.campaign.id)
    assert {campaign.daily_cap, campaign.max_daily_cap} == {6, 18}

    assert [job] = all_enqueued(worker: DailyReportEmail)
    assert [action] = job.args["actions"]
    assert action =~ "Permit contractors - Texas"
    assert action =~ "3 of 25 bounced"

    assert :ok = perform_job(DailyReportEmail, job.args)

    assert_email_sent(fn email ->
      assert email.to == [{"", "owner@example.com"}]
      assert email.subject =~ "1 drip(s) slowed"
      assert email.text_body =~ "Changed automatically"
      assert email.text_body =~ "/admin/report"
    end)
  end

  test "a quiet drip is left alone" do
    drip = setup_drip()
    for _ <- 1..30, do: send!(drip, yesterday())
    send!(drip, yesterday(), stopped: "bounced")

    assert :ok = perform_job(DailyReview, %{})
    assert Outreach.get_campaign!(drip.campaign.id).daily_cap == 12
  end

  test "slowing never goes below five a day" do
    drip = setup_drip("Small", %{daily_cap: 8, max_daily_cap: 9, ramp_per_day: 0})
    {:ok, _} = Reports.slow_campaign(Outreach.get_campaign!(drip.campaign.id), "test")
    campaign = Outreach.get_campaign!(drip.campaign.id)
    assert {campaign.daily_cap, campaign.max_daily_cap} == {5, 5}
  end

  test "opener test versions group by letter across markets, counted from the last version's start" do
    project = project_fixture()

    make = fn name ->
      c = campaign_fixture(project, %{name: name})
      step_fixture(c, %{"subject" => "First"})
      step_fixture(c, %{"subject" => "Second", "delay_days" => 3})
      {:ok, c} = Outreach.activate_campaign(Outreach.get_campaign!(c.id))
      c = Outreach.get_campaign!(c.id)
      %{project: project, campaign: c, step: hd(c.steps)}
    end

    tx_a = make.("Texas exteriors (A: texts & paper)")
    fl_a = make.("Florida exteriors (A: texts & paper)")
    tx_b = make.("Texas exteriors (B: price)")

    early = DateTime.add(yesterday(), -5 * 86_400)
    # A ran alone before the test: not counted.
    send!(tx_a, early)
    send!(tx_a, yesterday())
    send!(fl_a, yesterday(), reply: "Show me")
    send!(tx_b, yesterday(), stopped: "unsubscribed")

    [test] = Reports.opener_tests([project])
    [a, b] = test.variants

    assert {a.letter, a.label, a.sends, a.positive} == {"A", "texts & paper", 2, 1}
    assert {b.letter, b.sends, b.unsubscribed} == {"B", 1, 1}
    assert test.verdict =~ "Too early"
  end

  test "a range report covers every day in it, and slowing only shows for the morning view" do
    drip = setup_drip()
    w = Reports.window()
    week = Reports.range(Date.add(w.last, -6), w.last)

    send!(drip, yesterday())
    send!(drip, DateTime.add(yesterday(), -3 * 86_400))
    send!(drip, DateTime.add(yesterday(), -20 * 86_400))

    report = Reports.report(week, project_id: drip.project.id)
    assert [%{rows: [row]}] = report.projects
    assert row.sent == 2
    assert report.slow == []
    assert [%{sent: 2}] = report.addresses
  end

  test "range/2 is inclusive and puts backwards dates in order" do
    r = Reports.range(~D[2026-11-30], ~D[2026-11-01])
    assert {r.first, r.last} == {~D[2026-11-01], ~D[2026-11-30]}
    assert r.to == ~U[2026-12-01 05:00:00Z]
  end
end
