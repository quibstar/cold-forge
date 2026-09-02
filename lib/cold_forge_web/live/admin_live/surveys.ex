defmodule ColdForgeWeb.AdminLive.Surveys do
  @moduledoc """
  A project's surveys: named sets of questions, reusable across campaigns.

  Reusable is the point — asking the same question in three campaigns and
  comparing the answers is what makes this research rather than a poll.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs
  import ColdForgeWeb.SurveyQuestions

  alias ColdForge.Survey
  alias ColdForge.Survey.Question
  alias ColdForge.Survey.Survey, as: Sheet

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok, assign(socket, :project_id, project_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    surveys = Survey.list_surveys(socket.assigns.project_id)

    socket
    |> assign(:page_title, socket.assigns.current_project.name)
    |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
    |> assign(:surveys, surveys)
    |> assign(:answered, Map.new(surveys, &{&1.id, Survey.answered_count(&1.id)}))
  end

  defp apply_action(socket, :new, _params) do
    # Starts with one blank question rather than an empty list: a survey with no
    # questions isn't a thing anyone wants, and making them save, navigate, then
    # add one is two steps where there should be none.
    blank = %Sheet{questions: [%Question{kind: "choice"}]}

    socket
    |> assign(:page_title, "New survey")
    |> assign(:breadcrumbs, [
      {"Projects", ~p"/admin/projects"},
      {socket.assigns.current_project.name, ~p"/admin/p/#{socket.assigns.project_id}/surveys"}
    ])
    |> assign(:form, to_form(Sheet.changeset(blank, %{})))
  end

  @impl true
  def handle_event("validate", %{"survey" => params}, socket) do
    changeset =
      %Sheet{questions: []}
      |> Sheet.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"survey" => params}, socket) do
    params = Map.put(params, "project_id", socket.assigns.project_id)

    case Survey.create_survey(params) do
      {:ok, survey} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/admin/p/#{socket.assigns.project_id}/surveys/#{survey.id}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="flex justify-end mb-4">
      <.link navigate={~p"/admin/p/#{@project_id}/surveys/new"} class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="size-4" /> New survey
      </.link>
    </div>

    <div :if={@surveys == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-clipboard-document-list" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No surveys yet</h2>
        <p class="text-base-content/60 max-w-md">
          A survey is a few questions you link from an email. The first question
          goes in the email itself as one-click answers; the rest are asked on
          the page they land on.
        </p>
        <.link navigate={~p"/admin/p/#{@project_id}/surveys/new"} class="btn btn-primary mt-4">
          Create one
        </.link>
      </div>
    </div>

    <div :if={@surveys != []} class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Survey</th>
              <th>Questions</th>
              <th class="text-right">Answered</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={survey <- @surveys}>
              <td>
                <.link
                  navigate={~p"/admin/p/#{@project_id}/surveys/#{survey.id}"}
                  class="font-medium hover:text-primary"
                >
                  {survey.name}
                </.link>
              </td>
              <td class="text-sm text-base-content/60">{length(survey.questions)}</td>
              <td class="text-right tabular-nums">{@answered[survey.id]}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save" id="survey-form" class="space-y-4">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <.input field={@form[:name]} label="Survey name" placeholder="What hurts most" />
          <p class="text-xs text-base-content/50 -mt-2">Only you see this.</p>

          <.input
            type="textarea"
            field={@form[:intro]}
            label="Intro (optional)"
            rows="2"
            placeholder="Thanks — one more thing while you're here."
          />
          <p class="text-xs text-base-content/50 -mt-2">
            Shown above the questions. The email got them to click; this is the line
            that explains what they clicked into.
          </p>

          <.input
            type="textarea"
            field={@form[:thank_you]}
            label="Thank-you message (optional)"
            rows="2"
          />
        </div>
      </div>

      <.survey_questions form={@form} />

      <div class="flex justify-end gap-2">
        <.link navigate={~p"/admin/p/#{@project_id}/surveys"} class="btn btn-ghost">Cancel</.link>
        <button type="submit" class="btn btn-primary" phx-disable-with="Creating…">
          Create survey
        </button>
      </div>
    </.form>
    """
  end
end
