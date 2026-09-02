defmodule ColdForgeWeb.AdminLive.SurveyShow do
  @moduledoc """
  One survey: its questions, and what people answered.

  Results sit next to the question that produced them. Reading a tally in a
  separate reports screen means holding the wording in your head while you look
  at the numbers, and the wording is usually why the numbers came out the way
  they did.

  Editing is one form for the whole survey rather than a page per question —
  the questions are read together, so they're written together.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.SurveyQuestions

  alias ColdForge.Survey
  alias ColdForge.Survey.Question

  @impl true
  def mount(%{"project_id" => project_id, "id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:survey_id, id)
     |> load()}
  end

  defp load(socket) do
    survey = Survey.get_survey!(socket.assigns.survey_id)
    questions = Survey.list_questions(survey.id)

    socket
    |> assign(:survey, survey)
    |> assign(:questions, questions)
    |> assign(:results, Map.new(questions, &{&1.id, Survey.results(&1)}))
    |> assign(:answered, Survey.answered_count(survey.id))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.survey.name)
    |> assign(:breadcrumbs, survey_crumbs(socket))
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit survey")
    |> assign(
      :breadcrumbs,
      survey_crumbs(socket) ++ [{socket.assigns.survey.name, survey_path(socket.assigns)}]
    )
    |> assign(:form, to_form(Survey.change_survey(socket.assigns.survey)))
  end

  defp survey_crumbs(socket) do
    [
      {"Projects", ~p"/admin/projects"},
      {socket.assigns.current_project.name, ~p"/admin/p/#{socket.assigns.project_id}/surveys"}
    ]
  end

  defp survey_path(%{project_id: project_id, survey_id: survey_id}),
    do: ~p"/admin/p/#{project_id}/surveys/#{survey_id}"

  @impl true
  def handle_event("validate", %{"survey" => params}, socket) do
    changeset =
      socket.assigns.survey
      |> Survey.change_survey(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"survey" => params}, socket) do
    case Survey.update_survey(socket.assigns.survey, params) do
      {:ok, _survey} ->
        {:noreply,
         socket
         |> put_flash(:info, "Survey saved.")
         |> push_navigate(to: survey_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 mb-4">
      <span class="text-sm text-base-content/60">
        {length(@questions)} {if length(@questions) == 1, do: "question", else: "questions"} · {@answered} answered
      </span>
      <div class="ml-auto flex gap-2">
        <%!-- A real tab rather than a modal iframe: the answer page is a page,
        and seeing it at the size a recipient gets is the point of looking. --%>
        <.link
          :if={@questions != []}
          href={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/preview"}
          target="_blank"
          rel="noopener"
          class="btn btn-sm"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Preview
        </.link>
        <.link
          navigate={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/edit"}
          class="btn btn-sm btn-primary"
        >
          <.icon name="hero-pencil-square" class="size-4" /> Edit survey
        </.link>
      </div>
    </div>

    <div :if={@questions == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-question-mark-circle" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No questions yet</h2>
        <p class="text-base-content/60 max-w-md">
          Keep it short. The first question goes in the email as one-click
          answers, so make it the one you most want answered.
        </p>
        <.link
          navigate={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/edit"}
          class="btn btn-primary mt-4"
        >
          Write the questions
        </.link>
      </div>
    </div>

    <div class="space-y-3">
      <div :for={q <- @questions} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-center gap-2 text-xs text-base-content/50">
            <span class="badge badge-sm badge-ghost">{Question.kind_label(q.kind)}</span>
            <span :if={first?(q, @questions)}>asked in the email</span>
            <span :if={not first?(q, @questions)}>asked on the answer page</span>
          </div>
          <div class="font-medium mt-1">{q.prompt}</div>

          <.question_results question={q} results={@results[q.id]} />
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save" id="survey-form" class="space-y-4">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <.input field={@form[:name]} label="Survey name" />
          <.input type="textarea" field={@form[:intro]} label="Intro" rows="2" />
          <p class="text-xs text-base-content/50 -mt-2">
            Shown above the questions. The email got them to click; this is the line
            that explains what they clicked into.
          </p>
          <.input type="textarea" field={@form[:thank_you]} label="Thank-you message" rows="2" />
        </div>
      </div>

      <.survey_questions form={@form} />

      <div class="flex justify-end gap-2">
        <.link navigate={survey_path(assigns)} class="btn btn-ghost">Cancel</.link>
        <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
          Save survey
        </button>
      </div>
    </.form>
    """
  end

  # Positions order the questions but need not be a dense 1..n run — a
  # single-shot delete can leave a gap until the next save. "First" is therefore
  # first in the ordered list, not position 1.
  defp first?(question, questions), do: question.id == List.first(questions).id

  attr :question, :map, required: true
  attr :results, :map, required: true

  defp question_results(assigns) do
    ~H"""
    <div :if={@results.total > 0} class="mt-3 pt-3 border-t border-base-200">
      <div class="flex items-baseline gap-3 mb-2">
        <span class="text-xs text-base-content/50">
          {@results.total} {if @results.total == 1, do: "answer", else: "answers"}
        </span>
        <span :if={@results.average} class="text-sm font-medium text-primary">
          average {@results.average}
        </span>
      </div>

      <div :for={row <- @results.tally} class="flex items-center gap-2 text-xs mb-1">
        <div class="flex-1 min-w-0">
          <div class="truncate text-base-content/70">{row.label}</div>
          <div class="h-1.5 bg-base-200 rounded-full mt-0.5 overflow-hidden">
            <div
              class="h-full bg-primary rounded-full"
              style={"width: #{bar(row.count, @results.total)}%"}
            >
            </div>
          </div>
        </div>
        <span class="tabular-nums text-base-content/50 w-6 text-right">{row.count}</span>
      </div>

      <details :if={@results.comments != []} class="mt-2">
        <summary class="text-xs text-base-content/50 cursor-pointer">
          {length(@results.comments)} written {if length(@results.comments) == 1,
            do: "answer",
            else: "answers"} — usually where the useful part is
        </summary>
        <ul class="mt-2 space-y-2">
          <li :for={r <- @results.comments} class="text-sm border-l-2 border-base-300 pl-3">
            <p class="text-base-content/80 whitespace-pre-line">{r.text}</p>
            <p class="text-xs text-base-content/40 mt-0.5">
              {ColdForge.Outreach.Prospect.display_name(r.prospect)}
            </p>
          </li>
        </ul>
      </details>
    </div>

    <p
      :if={@results.total == 0}
      class="text-xs text-base-content/40 mt-3 pt-3 border-t border-base-200"
    >
      No answers yet.
    </p>
    """
  end

  defp bar(_count, 0), do: 0
  defp bar(count, total), do: round(count / total * 100)
end
