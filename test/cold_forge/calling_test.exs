defmodule ColdForge.CallingTest do
  @moduledoc """
  The call queue and what an outcome does.

  Most of these are about *not* dialling someone: the queue is the only thing
  that decides who gets rung, so every exclusion has to hold here rather than
  in the caller's memory.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Calling, Outreach}
  alias ColdForge.Workers.SendMessage

  setup do
    project = project_fixture(phone: "(616) 555-0142")
    %{project: project}
  end

  defp callable(project, attrs \\ []) do
    prospect_fixture(project, Keyword.merge([phone: "(616) 555-0100"], attrs))
  end

  describe "the queue" do
    test "offers people with a phone number, never called first", ctx do
      never = callable(ctx.project, first_name: "Never")
      called = callable(ctx.project, first_name: "Called")
      {:ok, _} = Calling.log_call(called, %{"outcome" => "no_answer"})

      queue = Calling.queue(ctx.project.id)

      # A first attempt is worth more than a fifth.
      assert hd(queue).id == never.id
      refute called.id in Enum.map(queue, & &1.id)
    end

    test "skips anyone without a phone number", ctx do
      prospect_fixture(ctx.project, phone: nil)
      assert Calling.queue(ctx.project.id) == []
    end

    test "skips people who asked not to be called", ctx do
      prospect = callable(ctx.project)
      {:ok, _} = Calling.log_call(prospect, %{"outcome" => "do_not_call"})

      assert Calling.queue(ctx.project.id) == []
    end

    test "skips people who already replied or unsubscribed", ctx do
      replied = callable(ctx.project)
      unsubscribed = callable(ctx.project)
      {:ok, _} = Outreach.mark_replied(replied)
      {:ok, _} = Outreach.unsubscribe_prospect(unsubscribed)

      assert Calling.queue(ctx.project.id) == []
    end

    test "holds someone back until their next slot comes round", ctx do
      prospect = callable(ctx.project)
      {:ok, _} = Calling.log_call(prospect, %{"outcome" => "no_answer"})

      assert Calling.queue(ctx.project.id) == []
      assert [held] = Calling.scheduled(ctx.project.id)
      assert held.id == prospect.id
      assert DateTime.compare(held.next_call_at, DateTime.utc_now()) == :gt
    end
  end

  describe "the cadence" do
    test "gaps widen with each attempt, then stop", ctx do
      prospect = callable(ctx.project)

      # A fixed reference, because `DateTime.diff/3` in days truncates — two
      # days minus a few microseconds reads as one.
      from = ~U[2026-09-02 12:00:00Z]

      gaps =
        for attempt <- 1..5 do
          case Calling.next_call_at("no_answer", attempt, from) do
            nil -> nil
            at -> DateTime.diff(at, from, :second) |> div(86_400)
          end
        end

      # Day 1, 3, 6, 9, 14 — and nothing after the fifth touch, because a sixth
      # call is not persistence.
      assert [2, 3, 3, 5, nil] = gaps
      _ = prospect
    end

    test "not now is a month, not a few days", ctx do
      from = ~U[2026-09-02 12:00:00Z]
      at = Calling.next_call_at("not_now", 1, from)
      assert DateTime.diff(at, from, :second) |> div(86_400) == 30
      _ = ctx
    end

    test "a closing outcome schedules nothing", ctx do
      for outcome <- ~w(not_interested do_not_call wrong_number connected interested) do
        assert Calling.next_call_at(outcome, 1) == nil
      end

      _ = ctx
    end
  end

  describe "voicemail scripts" do
    test "advance one at a time and stop after the breakup", ctx do
      prospect = callable(ctx.project)
      assert Calling.next_script(prospect.id) == 1

      for expected <- 1..4 do
        assert Calling.next_script(prospect.id) == expected
        prospect = Repo.reload(prospect)

        {:ok, _} =
          Calling.log_call(prospect, %{"outcome" => "voicemail", "voicemail_script" => expected})
      end

      # There is no fifth message that helps.
      assert Calling.next_script(prospect.id) == nil
    end
  end

  describe "what an outcome does beyond the phone" do
    setup ctx do
      campaign = campaign_fixture(ctx.project)
      step_fixture(campaign, %{"subject" => "One", "body" => "Hi"})
      step_fixture(campaign, %{"subject" => "Two", "body" => "Bump", "delay_days" => 3})
      campaign = Outreach.get_campaign!(campaign.id)

      prospect = callable(ctx.project)
      {:ok, _} = Outreach.send_campaign(campaign, [prospect.id])
      [enrollment] = Outreach.list_enrollments(campaign.id)
      :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

      %{prospect: Repo.reload(prospect), enrollment: enrollment}
    end

    test "speaking to someone stops their campaign", ctx do
      {:ok, _} = Calling.log_call(ctx.prospect, %{"outcome" => "connected"})

      # Following a conversation with a cold sequence reads as a machine that
      # was not listening.
      assert Repo.reload(ctx.prospect).status == "replied"
      assert Repo.reload(ctx.enrollment).status == "stopped"
    end

    test "asking not to be called stops the email too", ctx do
      {:ok, _} = Calling.log_call(ctx.prospect, %{"outcome" => "do_not_call"})

      prospect = Repo.reload(ctx.prospect)
      assert prospect.do_not_call
      assert prospect.status == "unsubscribed"
      # The point: answering "stop contacting me" by switching channel is the
      # behaviour that earns spam reports.
      assert Outreach.suppressed?(prospect.email)
      assert Repo.reload(ctx.enrollment).status == "stopped"
    end

    test "a wrong number says nothing about the email address", ctx do
      {:ok, _} = Calling.log_call(ctx.prospect, %{"outcome" => "wrong_number"})

      refute Outreach.suppressed?(ctx.prospect.email)
      assert Repo.reload(ctx.enrollment).status == "active"
    end

    test "a no-answer changes nothing on the email side", ctx do
      {:ok, _} = Calling.log_call(ctx.prospect, %{"outcome" => "no_answer"})

      assert Repo.reload(ctx.prospect).status == "new"
      assert Repo.reload(ctx.enrollment).status == "active"
    end
  end

  describe "history and counts" do
    test "records every attempt, not just the ones that connected", ctx do
      prospect = callable(ctx.project)

      for outcome <- ~w(no_answer no_answer voicemail) do
        {:ok, _} = Calling.log_call(Repo.reload(prospect), %{"outcome" => outcome})
      end

      # Four no-answers before a pickup is the normal shape of this work; a
      # history that hides them makes it look like nothing happened.
      assert length(Calling.list_calls(prospect.id)) == 3
      assert Repo.reload(prospect).call_attempts == 3

      stats = Calling.stats(ctx.project.id)
      assert stats.calls == 3
      assert stats.voicemails == 1
      assert stats.conversations == 0
    end
  end
end
