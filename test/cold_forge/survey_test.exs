defmodule ColdForge.SurveyTest do
  @moduledoc """
  The survey path from email to answer.

  The load-bearing assertion here is that fetching an answer link records
  nothing. Mail scanners fetch every URL in an email; a link that answered on
  being fetched would fill the results with responses nobody gave, which is
  worse for research than having no data at all.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Outreach, Survey}
  alias ColdForge.Workers.SendMessage

  setup do
    project = project_fixture()
    {:ok, survey} = Survey.create_survey(%{project_id: project.id, name: "What hurts"})
    %{project: project, survey: survey}
  end

  defp question(survey, attrs) do
    {:ok, q} = Survey.create_question(survey, attrs)
    q
  end

  # A campaign whose first email links to the survey, sent to one prospect.
  defp send_to_prospect(project, survey) do
    campaign = campaign_fixture(project)

    {:ok, step} =
      Outreach.create_step(campaign, %{
        "subject" => "Quick one",
        "body" => "Hi {{first_name}},\n\n{{survey}}",
        "survey_id" => survey.id
      })

    # A follow-up, so the enrollment is still running after the first send —
    # otherwise it completes and there is nothing for an answer to stop.
    {:ok, _} =
      Outreach.create_step(campaign, %{
        "subject" => "Following up",
        "body" => "Just bumping this.",
        "delay_days" => 3
      })

    campaign = Outreach.get_campaign!(campaign.id)
    prospect = prospect_fixture(project)
    {:ok, _} = Outreach.send_campaign(campaign, [prospect.id])
    [enrollment] = Outreach.list_enrollments(campaign.id)
    :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

    message =
      Outreach.list_messages(project.id) |> Enum.find(&(&1.enrollment_id == enrollment.id))

    %{
      campaign: campaign,
      step: step,
      prospect: prospect,
      message: message,
      enrollment: enrollment
    }
  end

  describe "question kinds" do
    test "a pick-one offers each option as a one-click link", ctx do
      question(ctx.survey, %{
        "kind" => "choice",
        "prompt" => "Worst bit?",
        "options" => "Scheduling\nInvoicing"
      })

      %{message: message} = send_to_prospect(ctx.project, ctx.survey)

      assert message.body =~ "Worst bit?"
      assert message.body =~ "Scheduling: "
      assert message.body =~ "Invoicing: "
      # Two options, two distinct links.
      assert length(Regex.scan(~r{/a/[\w-]+}, message.body)) == 2
    end

    test "a rating offers each point on the scale", ctx do
      question(ctx.survey, %{"kind" => "rating", "prompt" => "How bad?"})

      %{message: message} = send_to_prospect(ctx.project, ctx.survey)

      assert length(Regex.scan(~r{/a/[\w-]+}, message.body)) == 5
    end

    test "NPS runs 0 to 10, so eleven links", ctx do
      question(ctx.survey, %{"kind" => "nps", "prompt" => "Recommend us?"})

      %{message: message} = send_to_prospect(ctx.project, ctx.survey)

      assert length(Regex.scan(~r{/a/[\w-]+}, message.body)) == 11
    end

    test "free text gets one plain link, since a click can't express it", ctx do
      question(ctx.survey, %{"kind" => "text", "prompt" => "What would you change?"})

      %{message: message} = send_to_prospect(ctx.project, ctx.survey)

      assert length(Regex.scan(~r{/a/[\w-]+}, message.body)) == 1
    end

    test "pick-any gets one plain link — one click can't mean 'these three'", ctx do
      question(ctx.survey, %{
        "kind" => "multi",
        "prompt" => "Which apply?",
        "options" => "A\nB\nC"
      })

      %{message: message} = send_to_prospect(ctx.project, ctx.survey)

      assert length(Regex.scan(~r{/a/[\w-]+}, message.body)) == 1
    end

    test "an email with no survey linked drops the tag rather than printing it", ctx do
      campaign = campaign_fixture(ctx.project)

      {:ok, _} =
        Outreach.create_step(campaign, %{"subject" => "Hi", "body" => "Text {{survey}} end"})

      campaign = Outreach.get_campaign!(campaign.id)
      prospect = prospect_fixture(ctx.project)
      {:ok, _} = Outreach.send_campaign(campaign, [prospect.id])
      [e] = Outreach.list_enrollments(campaign.id)
      :ok = perform_job(SendMessage, %{enrollment_id: e.id})

      [message] = Outreach.list_messages(ctx.project.id)
      refute message.body =~ "{{survey}}"
    end
  end

  describe "answering" do
    setup ctx do
      q =
        question(ctx.survey, %{
          "kind" => "choice",
          "prompt" => "Worst bit?",
          "options" => "Scheduling\nInvoicing"
        })

      sent = send_to_prospect(ctx.project, ctx.survey)

      link =
        Repo.get_by!(ColdForge.Survey.Link, message_id: sent.message.id, choice: "Scheduling")

      Map.merge(sent, %{question: q, link: Survey.get_answer_link(link.token)})
    end

    test "fetching the link records nothing", ctx do
      # This is the scanner-prefetch guarantee. `get_answer_link/1` is exactly
      # what a GET does, and it must leave the results untouched.
      assert Survey.answered_count(ctx.survey.id) == 0
      assert Survey.results(ctx.question).total == 0
      assert Repo.reload(ctx.enrollment).status == "active"
    end

    test "confirming records the answer and stops the campaign", ctx do
      {:ok, saved} =
        Survey.record_answers(ctx.link, %{
          to_string(ctx.question.id) => %{"choice" => "Scheduling"}
        })

      assert length(saved) == 1
      assert Survey.answered_count(ctx.survey.id) == 1

      enrollment = Repo.reload(ctx.enrollment)
      assert enrollment.status == "stopped"
      assert enrollment.stopped_reason == "answered"
      assert enrollment.answered_at
    end

    test "leaves the campaign running when told to", ctx do
      {:ok, _} = Outreach.update_campaign(ctx.campaign, %{stop_on_answer: false})
      # The link carries a preloaded campaign, so re-read it after the change.
      link = Survey.get_answer_link(ctx.link.token)

      {:ok, _} =
        Survey.record_answers(link, %{
          to_string(ctx.question.id) => %{"choice" => "Scheduling"}
        })

      enrollment = Repo.reload(ctx.enrollment)
      assert enrollment.status == "active"
      assert enrollment.answered_at
    end

    test "an empty submit is not an answer", ctx do
      {:ok, saved} =
        Survey.record_answers(ctx.link, %{
          to_string(ctx.question.id) => %{"choice" => "", "text" => "  "}
        })

      assert saved == []
      assert Survey.answered_count(ctx.survey.id) == 0
      # And it must not have stopped the campaign either.
      assert Repo.reload(ctx.enrollment).status == "active"
    end

    test "changing your mind corrects the record rather than adding a second", ctx do
      qid = to_string(ctx.question.id)
      {:ok, _} = Survey.record_answers(ctx.link, %{qid => %{"choice" => "Scheduling"}})
      {:ok, _} = Survey.record_answers(ctx.link, %{qid => %{"choice" => "Invoicing"}})

      results = Survey.results(ctx.question)
      assert results.total == 1
      assert Enum.find(results.tally, &(&1.label == "Invoicing")).count == 1
      assert Enum.find(results.tally, &(&1.label == "Scheduling")).count == 0
    end
  end

  describe "results" do
    test "keeps options nobody picked", ctx do
      q = question(ctx.survey, %{"kind" => "choice", "prompt" => "?", "options" => "A\nB\nC"})

      # "Nobody picked C" is a finding; dropping the row would hide it.
      assert Enum.map(Survey.results(q).tally, & &1.label) == ["A", "B", "C"]
    end

    test "averages a numeric scale and nothing else", ctx do
      rating = question(ctx.survey, %{"kind" => "rating", "prompt" => "How bad?"})
      choice = question(ctx.survey, %{"kind" => "choice", "prompt" => "?", "options" => "A\nB"})

      sent = send_to_prospect(ctx.project, ctx.survey)

      token =
        Repo.get_by!(ColdForge.Survey.Link,
          message_id: sent.message.id,
          survey_question_id: rating.id,
          choice: "4"
        ).token

      link = Survey.get_answer_link(token)

      {:ok, _} =
        Survey.record_answers(link, %{
          to_string(rating.id) => %{"number" => "4"},
          to_string(choice.id) => %{"choice" => "A"}
        })

      assert Survey.results(rating).average == 4.0
      # An average of "A" and "B" is not a number.
      assert Survey.results(choice).average == nil
    end
  end

  describe "previewing" do
    test "the email preview renders the survey rather than the raw tag", ctx do
      q =
        question(ctx.survey, %{
          "position" => 1,
          "kind" => "choice",
          "prompt" => "Worst bit?",
          "options" => "Scheduling\nInvoicing"
        })

      prospect = prospect_fixture(ctx.project, first_name: "Sam")

      preview =
        ColdForge.Sending.Renderer.preview_message(
          "Hi",
          "Hi {{first_name}},\n\n{{survey}}",
          prospect,
          ctx.project,
          question: q,
          base_url: "https://cold.example"
        )

      # The point of previewing is catching what the recipient gets. A literal
      # {{survey}} in the preview would be the preview lying.
      refute preview.text =~ "{{survey}}"
      assert preview.text =~ "Worst bit?"
      assert preview.text =~ "Scheduling: https://cold.example/a/preview0"
      assert preview.text =~ "Invoicing: https://cold.example/a/preview1"
    end

    test "previewing creates no answer links", ctx do
      q =
        question(ctx.survey, %{
          "position" => 1,
          "kind" => "choice",
          "prompt" => "?",
          "options" => "A\nB"
        })

      prospect = prospect_fixture(ctx.project)

      ColdForge.Sending.Renderer.preview_message("s", "{{survey}}", prospect, ctx.project,
        question: q
      )

      # A real link per keystroke would leave a trail of dead rows.
      assert Repo.aggregate(ColdForge.Survey.Link, :count) == 0
    end

    test "an email with no survey linked previews without the tag", ctx do
      prospect = prospect_fixture(ctx.project)

      preview =
        ColdForge.Sending.Renderer.preview_message(
          "s",
          "Text {{survey}} end",
          prospect,
          ctx.project
        )

      refute preview.text =~ "{{survey}}"
    end
  end

  describe "editing questions through the survey form" do
    test "adds, reorders and removes in one save", ctx do
      {:ok, survey} =
        Survey.update_survey(ctx.survey, %{
          "name" => "What hurts",
          "questions" => %{
            "0" => %{
              "position" => "1",
              "kind" => "choice",
              "prompt" => "First",
              "options" => "A\nB"
            },
            "1" => %{"position" => "2", "kind" => "text", "prompt" => "Second"}
          },
          "questions_order" => ["0", "1"]
        })

      assert [%{position: 1, prompt: "First"}, %{position: 2, prompt: "Second"}] =
               Survey.list_questions(survey.id)
    end

    test "removing the first question renumbers the rest", ctx do
      {:ok, survey} =
        Survey.update_survey(ctx.survey, %{
          "questions" => %{
            "0" => %{"position" => "1", "kind" => "text", "prompt" => "One"},
            "1" => %{"position" => "2", "kind" => "text", "prompt" => "Two"},
            "2" => %{"position" => "3", "kind" => "text", "prompt" => "Three"}
          },
          "questions_order" => ["0", "1", "2"]
        })

      questions = Survey.list_questions(survey.id)

      params =
        questions
        |> Enum.with_index()
        |> Map.new(fn {q, i} ->
          {to_string(i),
           %{
             "id" => to_string(q.id),
             "position" => to_string(i + 1),
             "kind" => q.kind,
             "prompt" => q.prompt
           }}
        end)

      {:ok, survey} =
        Survey.update_survey(survey, %{
          "questions" => params,
          "questions_order" => ["0", "1", "2"],
          "questions_delete" => ["0"]
        })

      # The survivors keep their order; the email asks whichever is first.
      assert ["Two", "Three"] = Enum.map(Survey.list_questions(survey.id), & &1.prompt)
    end

    test "rejects a pick-one with fewer than two options", ctx do
      assert {:error, changeset} =
               Survey.update_survey(ctx.survey, %{
                 "questions" => %{
                   "0" => %{
                     "position" => "1",
                     "kind" => "choice",
                     "prompt" => "?",
                     "options" => "A"
                   }
                 },
                 "questions_order" => ["0"]
               })

      assert [%{options: ["needs at least two options"]}] = errors_on(changeset).questions
    end
  end

  describe "creating a survey with its questions" do
    test "one save creates both", ctx do
      {:ok, survey} =
        Survey.create_survey(%{
          "project_id" => ctx.project.id,
          "name" => "Written in one go",
          "questions" => %{
            "0" => %{
              "position" => "1",
              "kind" => "choice",
              "prompt" => "Worst bit?",
              "options" => "Scheduling\nInvoicing"
            },
            "1" => %{"position" => "2", "kind" => "text", "prompt" => "Anything else?"}
          },
          "questions_order" => ["0", "1"]
        })

      assert [
               %{position: 1, kind: "choice", options: ["Scheduling", "Invoicing"]},
               %{position: 2, kind: "text", prompt: "Anything else?"}
             ] = Survey.list_questions(survey.id)
    end

    test "an invalid question stops the survey being created too", ctx do
      before = length(Survey.list_surveys(ctx.project.id))

      assert {:error, _changeset} =
               Survey.create_survey(%{
                 "project_id" => ctx.project.id,
                 "name" => "Broken",
                 "questions" => %{
                   "0" => %{
                     "position" => "1",
                     "kind" => "choice",
                     "prompt" => "?",
                     "options" => "A"
                   }
                 },
                 "questions_order" => ["0"]
               })

      assert length(Survey.list_surveys(ctx.project.id)) == before
    end
  end

  describe "surveys are reusable" do
    test "the same survey answered from two campaigns pools its results", ctx do
      q = question(ctx.survey, %{"kind" => "choice", "prompt" => "?", "options" => "A\nB"})

      for _ <- 1..2 do
        sent = send_to_prospect(ctx.project, ctx.survey)

        token =
          Repo.get_by!(ColdForge.Survey.Link, message_id: sent.message.id, choice: "A").token

        {:ok, _} =
          Survey.record_answers(Survey.get_answer_link(token), %{
            to_string(q.id) => %{"choice" => "A"}
          })
      end

      # Two campaigns, one comparable result set — the reason a survey belongs
      # to the project rather than to a campaign.
      assert Survey.results(q).total == 2
    end
  end
end
