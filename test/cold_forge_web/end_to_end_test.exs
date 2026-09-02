defmodule ColdForgeWeb.EndToEndTest do
  @moduledoc """
  The whole journey, once, in order: import a list, write a survey, write a
  campaign, send it, and follow what a recipient does next.

  Every other test in the suite checks one part in isolation. This one exists
  because the parts can each be right while the seams between them are wrong —
  a merge tag that renders in a unit test but gets eaten by an earlier pass, a
  link that resolves but records against the wrong campaign.
  """
  use ColdForgeWeb.ConnCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import Swoosh.TestAssertions

  alias ColdForge.{Outreach, Repo, Survey}
  alias ColdForge.Outreach.Importer
  alias ColdForge.Workers.{CampaignScheduler, SendMessage}

  test "from a CSV to an answered survey" do
    base_url = ColdForgeWeb.Endpoint.url()

    ## 1. A project — sender identity, landing page, and the compliance bits.

    {:ok, project} =
      Outreach.create_project(%{
        name: "ExteriorPro",
        from_name: "Kris Utter",
        from_email: "kris@exteriorpro.io",
        landing_url: "https://exteriorpro.io/demo",
        postal_address: "123 Main St, Springfield, IL 62701",
        signature: "Kris Utter\nExteriorPro",
        industry: "contractors",
        timezone: "America/New_York"
      })

    ## 2. Import a list. One row is already on the do-not-contact list, one has
    ##    a broken address, and one repeats — all three routinely turn up in a
    ##    bought list.

    Outreach.suppress("opted.out@example.com", "unsubscribed")

    csv = """
    Email Address,First Name,Last Name,Company,Job Title,Industry,Roof Type
    marcus@webbroofing.com,Marcus,Webb,Webb Roofing,Owner,roofing,Asphalt
    dana@northsidesiding.com,Dana,Okafor,Northside Siding,GM,siding,
    lena@ortizexteriors.com,Lena,Ortiz,Ortiz Exteriors,Owner,,Metal
    opted.out@example.com,Nope,Nope,Nope Co,Owner,roofing,
    marcus@webbroofing.com,Marcus,Webb,Webb Roofing,Owner,roofing,Asphalt
    not-an-email,Broken,Row,Nowhere,,,
    """

    headers = [
      "Email Address",
      "First Name",
      "Last Name",
      "Company",
      "Job Title",
      "Industry",
      "Roof Type"
    ]

    mapping = headers |> Importer.guess_mapping() |> Map.put(:__headers__, headers)

    {:ok, analysis} = Importer.analyze(csv, project.id, mapping)
    assert analysis.counts == %{new: 3, suppressed: 1, duplicate: 1, invalid: 1}

    {:ok, %{inserted: 3}} = Importer.commit(csv, project.id, mapping)

    prospects = Outreach.list_prospects(project.id)
    assert length(prospects) == 3
    marcus = Enum.find(prospects, &(&1.email == "marcus@webbroofing.com"))
    lena = Enum.find(prospects, &(&1.email == "lena@ortizexteriors.com"))
    dana = Enum.find(prospects, &(&1.email == "dana@northsidesiding.com"))

    # A column nobody mapped is still reachable from a merge tag.
    assert marcus.custom_fields["roof_type"] == "Asphalt"
    assert marcus.industry == "roofing"

    ## 3. A survey. The first question goes in the email; the second is asked on
    ##    the page they land on.

    {:ok, survey} =
      Survey.create_survey(%{
        project_id: project.id,
        name: "What hurts",
        intro: "One quick thing while you're here.",
        thank_you: "Genuinely useful — thank you."
      })

    {:ok, survey} =
      Survey.update_survey(survey, %{
        "questions" => %{
          "0" => %{
            "position" => "1",
            "kind" => "choice",
            "prompt" => "What eats the most time?",
            "options" => "Scheduling\nInvoicing\nQuoting"
          },
          "1" => %{"position" => "2", "kind" => "text", "prompt" => "Anything else?"}
        },
        "questions_order" => ["0", "1"]
      })

    [first_question, second_question] = Survey.list_questions(survey.id)

    ## 4. A campaign: an opener that asks the survey, and a follow-up three days
    ##    later.

    # Pinned to a weekday two days out, so "nothing is due yet" below holds
    # whatever time the suite runs at — enrolling inside the send window makes
    # somebody due immediately, which is correct behaviour, not a bug.
    send_day =
      DateTime.utc_now()
      |> DateTime.shift_zone!(project.timezone)
      |> DateTime.to_date()
      |> Date.add(2)
      |> Date.day_of_week()

    {:ok, campaign} =
      Outreach.create_campaign(%{
        "project_id" => project.id,
        "name" => "Roofers — spring",
        "send_days" => [send_day]
      })

    {:ok, _opener} =
      Outreach.create_step(campaign, %{
        "subject" => "Quick question about {{company}}",
        "body" => """
        Hi {{first_name|there}},

        I build software for {{industry|contractors}}.

        {{survey}}

        Or see it here: {{link}}
        """,
        "survey_id" => survey.id
      })

    {:ok, _follow_up} =
      Outreach.create_step(campaign, %{
        "subject" => "Re: {{company}}",
        "body" => "Just bumping this, {{first_name|there}}.",
        "delay_days" => 3
      })

    campaign = Outreach.get_campaign!(campaign.id)

    ## 5. Enroll everyone and let the scheduler decide who is due.

    {:ok, %{enrolled: 3, skipped: 0}} =
      Outreach.send_campaign(campaign, Enum.map(prospects, & &1.id))

    assert Outreach.get_campaign!(campaign.id).status == "active"

    # Nothing is due yet — the send window pushed everyone to that future day.
    assert :ok = perform_job(CampaignScheduler, %{})
    refute_enqueued(worker: SendMessage)

    make_due(campaign.id)
    assert :ok = perform_job(CampaignScheduler, %{})
    assert length(all_enqueued(worker: SendMessage)) == 3

    ## 6. Send them.

    for enrollment <- Outreach.list_enrollments(campaign.id) do
      assert :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})
    end

    # `perform_job/2` runs a job without consuming the queued one, so clear it
    # here — later assertions are about newly scheduled work, not this round.
    clear_queue()

    messages = Outreach.list_messages(project.id)
    assert length(messages) == 3

    to_marcus = Enum.find(messages, &(&1.prospect_id == marcus.id))
    body = to_marcus.body

    ## 7. What actually went out.

    assert to_marcus.status == "sent"
    assert to_marcus.subject == "Quick question about Webb Roofing"
    assert body =~ "Hi Marcus,"
    # {{industry}} resolved from the prospect...
    assert body =~ "I build software for roofing."
    # ...and the survey rendered with a link per option.
    assert body =~ "What eats the most time?"
    assert body =~ "Scheduling: #{base_url}/a/"
    assert body =~ "Invoicing: #{base_url}/a/"
    assert body =~ "Quoting: #{base_url}/a/"
    # The landing page is tokenised, never sent raw.
    refute body =~ "https://exteriorpro.io/demo"
    assert body =~ "#{base_url}/c/"
    # Signature, then the compliance footer.
    assert body =~ "Kris Utter\nExteriorPro"
    assert body =~ "#{base_url}/u/#{marcus.unsubscribe_token}"
    assert body =~ "123 Main St, Springfield, IL 62701"
    # No tag survived any pass.
    refute body =~ "{{"

    # Lena has no industry of her own, so the project's value stands in.
    to_lena = Enum.find(messages, &(&1.prospect_id == lena.id))
    assert to_lena.body =~ "I build software for contractors."

    assert_email_sent(fn email ->
      assert {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"} in email.headers
    end)

    ## 8. Marcus clicks the demo link.

    [tracked] = Outreach.get_message!(to_marcus.id).tracked_links

    conn = get(build_conn(), ~p"/c/#{tracked.token}")
    assert redirected_to(conn) == "https://exteriorpro.io/demo?cf=#{tracked.token}"
    assert Repo.reload(tracked).click_count == 1

    ## 9. His mail client fetches the tracking pixel, then the survey link — the
    ##    scanner case. The pixel counts; the survey link must not.

    get(build_conn(), ~p"/o/#{to_marcus.open_token <> ".png"}")
    assert Repo.reload(to_marcus).open_count == 1

    answer_link =
      Repo.get_by!(ColdForge.Survey.Link,
        message_id: to_marcus.id,
        survey_question_id: first_question.id,
        choice: "Scheduling"
      )

    conn = get(build_conn(), ~p"/a/#{answer_link.token}")
    html = html_response(conn, 200)
    assert html =~ "What eats the most time?"
    # Pre-selected, and the second question is asked here too.
    assert html =~ "Anything else?"
    # Escaped in the response, so match the part without the apostrophe.
    assert html =~ "One quick thing while you"

    # The load-bearing assertion of this whole feature.
    assert Survey.answered_count(survey.id) == 0
    assert Repo.reload(marcus_enrollment(campaign.id, marcus.id)).status == "active"

    ## 10. He confirms, and adds a comment on the second question.

    conn =
      post(build_conn(), ~p"/a/#{answer_link.token}", %{
        "answers" => %{
          to_string(first_question.id) => %{"choice" => "Scheduling", "text" => "Crews overlap."},
          to_string(second_question.id) => %{"text" => "Quoting is fine, scheduling isn't."}
        }
      })

    assert html_response(conn, 200) =~ "Genuinely useful"
    assert Survey.answered_count(survey.id) == 1

    results = Survey.results(first_question)
    assert Enum.find(results.tally, &(&1.label == "Scheduling")).count == 1
    assert Enum.find(results.tally, &(&1.label == "Quoting")).count == 0
    assert [%{text: "Crews overlap."}] = results.comments

    # Answering stopped his campaign — no follow-up chasing somebody who just
    # told you something.
    enrollment = Repo.reload(marcus_enrollment(campaign.id, marcus.id))
    assert enrollment.status == "stopped"
    assert enrollment.stopped_reason == "answered"
    assert enrollment.answered_at

    ## 11. Dana unsubscribes. GET must not act; POST must.

    conn = get(build_conn(), ~p"/u/#{dana.unsubscribe_token}")
    assert html_response(conn, 200) =~ "Unsubscribe"
    assert Repo.reload(dana).status == "new"

    conn = post(build_conn(), ~p"/u/#{dana.unsubscribe_token}")
    assert html_response(conn, 200) =~ "unsubscribed"

    assert Repo.reload(dana).status == "unsubscribed"
    assert Outreach.suppressed?(dana.email)
    assert Repo.reload(marcus_enrollment(campaign.id, dana.id)).status == "stopped"

    ## 12. Only Lena is left running, and only she gets the follow-up.

    make_due(campaign.id)
    assert :ok = perform_job(CampaignScheduler, %{})
    assert [job] = all_enqueued(worker: SendMessage)
    assert job.args["enrollment_id"] == marcus_enrollment(campaign.id, lena.id).id

    assert :ok = perform_job(SendMessage, %{enrollment_id: job.args["enrollment_id"]})

    follow_ups =
      Outreach.list_messages(project.id) |> Enum.filter(&(&1.subject =~ "Re: "))

    assert length(follow_ups) == 1
    assert hd(follow_ups).prospect_id == lena.id
    assert Repo.reload(marcus_enrollment(campaign.id, lena.id)).status == "completed"

    ## 13. Dana's address is now radioactive everywhere, including a re-import
    ##     into a different project.

    {:ok, other} =
      Outreach.create_project(%{
        name: "Second idea",
        from_name: "Kris",
        from_email: "kris@second.io"
      })

    reimport = "Email\n#{dana.email}\n"
    {:ok, again} = Importer.analyze(reimport, other.id, %{email: 0, __headers__: ["Email"]})
    assert again.counts == %{suppressed: 1}

    ## 14. The numbers the dashboard shows.

    stats = Outreach.project_stats(project.id)
    assert stats.prospects == 3
    assert stats.sent == 4
    assert stats.opened == 1
    assert stats.clicked == 1

    campaign_stats = Outreach.campaign_stats(campaign.id)
    assert campaign_stats.sent == 4
    assert campaign_stats.clicked == 1
  end

  defp clear_queue, do: Repo.delete_all(Oban.Job)

  # Enrollments are scheduled into the send window, usually days out. Backdating
  # is how the test says "this one has come due".
  defp make_due(campaign_id) do
    import Ecto.Query

    from(e in ColdForge.Outreach.Enrollment,
      where: e.campaign_id == ^campaign_id and e.status == "active"
    )
    |> Repo.update_all(
      set: [
        next_send_at:
          DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
      ]
    )
  end

  defp marcus_enrollment(campaign_id, prospect_id) do
    Repo.get_by!(ColdForge.Outreach.Enrollment,
      campaign_id: campaign_id,
      prospect_id: prospect_id
    )
  end
end
