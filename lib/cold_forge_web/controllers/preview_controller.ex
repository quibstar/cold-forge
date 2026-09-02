defmodule ColdForgeWeb.PreviewController do
  @moduledoc """
  Full-page previews of the two things a recipient actually sees: the email,
  and the survey's answer page.

  Both render the *real* thing rather than an admin approximation — the answer
  page uses the public template, and the email uses the same renderer the send
  path uses. A preview that draws its own version is a preview of nothing; it
  drifts the first time the real one changes.

  Nothing here is recordable: no answer link exists, no message row is written,
  and the survey form is inert.
  """
  use ColdForgeWeb, :controller

  # Reuses the public page's own module so the preview can't drift from it.
  plug :put_view, html: ColdForgeWeb.TrackingHTML

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect
  alias ColdForge.Sending.Renderer
  alias ColdForge.Survey
  alias ColdForge.Survey.Question

  def survey(conn, %{"id" => id}) do
    survey = Survey.get_survey!(id)
    questions = Survey.list_questions(survey.id)

    conn
    |> put_root_layout(html: {ColdForgeWeb.Layouts, :root})
    |> render(:answer_form,
      layout: false,
      page_title: "Preview",
      survey: survey,
      questions: questions,
      responses: %{},
      preview: true,
      # A stand-in for the row a real click carries. The first answer is
      # pre-selected because that's what a recipient would arrive with.
      link: %{
        token: "preview",
        survey_question_id: questions |> List.first() |> then(&(&1 && &1.id)),
        choice: questions |> List.first() |> preselected_choice()
      }
    )
  end

  @doc """
  The email as it will be sent, as a standalone page.

  Served as the raw message HTML, not wrapped in the admin layout — the point
  is to see the mail's own markup at full width.
  """
  def email(conn, %{"step_id" => step_id}) do
    step = Outreach.get_step!(step_id)
    campaign = Outreach.get_campaign!(step.campaign_id)
    project = Outreach.get_project!(campaign.project_id)

    preview =
      Renderer.preview_message(
        step.subject,
        step.body,
        preview_prospect(project),
        project,
        branded: campaign.branded,
        question: Survey.email_question(step.survey_id)
      )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, preview.html)
  end

  # A real prospect is the honest thing to render against; the placeholder only
  # appears on a project with nobody in it yet.
  defp preview_prospect(project) do
    case Outreach.list_prospects(project.id) do
      [first | _] ->
        first

      [] ->
        %Prospect{
          first_name: "Sam",
          last_name: "Rivera",
          email: "sam@example.com",
          company: "Rivera Roofing",
          title: "Owner",
          unsubscribe_token: "preview"
        }
    end
  end

  defp preselected_choice(nil), do: nil

  defp preselected_choice(%Question{} = question) do
    question |> Question.clickable_answers() |> List.first()
  end
end
