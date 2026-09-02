defmodule ColdForgeWeb.SurveyPreviewController do
  @moduledoc """
  Renders a survey's answer page as a recipient sees it.

  Deliberately renders the *real* public template rather than an admin
  approximation. A preview that draws its own version of the page is a preview
  of nothing — it drifts the first time the real page changes.

  Nothing here is recordable: the form is inert, and no answer link exists.
  """
  use ColdForgeWeb, :controller

  # Reuses the public page's own module so the preview can't drift from it.
  plug :put_view, html: ColdForgeWeb.TrackingHTML

  alias ColdForge.Survey
  alias ColdForge.Survey.Question

  def show(conn, %{"id" => id}) do
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

  defp preselected_choice(nil), do: nil

  defp preselected_choice(%Question{} = question) do
    question |> Question.clickable_answers() |> List.first()
  end
end
