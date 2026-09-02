defmodule ColdForgeWeb.AdminLive.SurveyShow do
  @moduledoc """
  One survey: its questions, and what people answered.

  Results sit next to the question that produced them. Reading a tally in a
  separate reports screen means holding the wording in your head while you look
  at the numbers, and the wording is usually why the numbers came out that way.
  """
  use ColdForgeWeb, :live_view

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

  defp apply_action(socket, :new_question, _params) do
    socket
    |> assign(:page_title, "New question")
    |> assign(
      :breadcrumbs,
      survey_crumbs(socket) ++ [{socket.assigns.survey.name, survey_path(socket.assigns)}]
    )
    |> assign(:question, %Question{})
    |> assign(:form, question_form(%Question{}))
  end

  defp apply_action(socket, :edit_question, %{"question_id" => id}) do
    question = Survey.get_question!(id)

    socket
    |> assign(:page_title, "Question #{question.position}")
    |> assign(
      :breadcrumbs,
      survey_crumbs(socket) ++ [{socket.assigns.survey.name, survey_path(socket.assigns)}]
    )
    |> assign(:question, question)
    |> assign(:form, question_form(question))
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

  # Options are edited as one-per-line text — how you actually think about a
  # short list, rather than a repeating form field group.
  defp question_form(%Question{} = question) do
    to_form(
      %{
        "kind" => question.kind || "choice",
        "prompt" => question.prompt || "",
        "options" => Enum.join(question.options || [], "\n")
      },
      as: :question
    )
  end

  @impl true
  def handle_event("validate_question", %{"question" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :question))}
  end

  def handle_event("save_question", %{"question" => params}, socket) do
    attrs = %{
      "kind" => params["kind"],
      "prompt" => params["prompt"],
      "options" => params["options"] || ""
    }

    result =
      case socket.assigns.live_action do
        :new_question -> Survey.create_question(socket.assigns.survey, attrs)
        :edit_question -> Survey.update_question(socket.assigns.question, attrs)
      end

    case result do
      {:ok, _question} ->
        {:noreply,
         socket
         |> put_flash(:info, "Question saved.")
         |> push_navigate(to: survey_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_summary(changeset))
         |> assign(:form, to_form(params, as: :question))}
    end
  end

  def handle_event("delete_question", %{"id" => id}, socket) do
    {:ok, :ok} = id |> Survey.get_question!() |> Survey.delete_question()
    {:noreply, socket |> put_flash(:info, "Question removed.") |> load()}
  end

  def handle_event("save_survey", %{"survey" => params}, socket) do
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

  defp error_summary(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 mb-4">
      <span class="text-sm text-base-content/60">
        {length(@questions)} {if length(@questions) == 1, do: "question", else: "questions"} · {@answered} answered
      </span>
      <div class="ml-auto flex gap-2">
        <.link
          navigate={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/edit"}
          class="btn btn-sm btn-ghost"
        >
          Edit survey
        </.link>
        <.link
          navigate={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/questions/new"}
          class="btn btn-sm btn-primary"
        >
          <.icon name="hero-plus" class="size-4" /> Add question
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
      </div>
    </div>

    <div class="space-y-3">
      <div :for={q <- @questions} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 text-xs text-base-content/50">
                <span class="badge badge-sm badge-ghost">{Question.kind_label(q.kind)}</span>
                <span :if={q.position == 1}>asked in the email</span>
                <span :if={q.position > 1}>asked on the answer page</span>
              </div>
              <div class="font-medium mt-1">{q.prompt}</div>
            </div>
            <div class="flex gap-1 shrink-0">
              <.link
                navigate={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/questions/#{q.id}"}
                class="btn btn-xs btn-ghost"
              >
                Edit
              </.link>
              <button
                phx-click="delete_question"
                phx-value-id={q.id}
                data-confirm="Delete this question and every answer to it?"
                class="btn btn-xs btn-ghost text-error"
              >
                Delete
              </button>
            </div>
          </div>

          <.question_results question={q} results={@results[q.id]} />
        </div>
      </div>
    </div>
    """
  end

  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <.form for={@form} phx-submit="save_survey" id="survey-edit-form" class="space-y-4">
          <.input field={@form[:name]} label="Survey name" />
          <.input type="textarea" field={@form[:intro]} label="Intro" rows="2" />
          <.input type="textarea" field={@form[:thank_you]} label="Thank-you message" rows="2" />

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={survey_path(assigns)} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <.form
          for={@form}
          phx-change="validate_question"
          phx-submit="save_question"
          id="question-form"
          class="space-y-4"
        >
          <div>
            <label class="text-sm font-medium">Answer type</label>
            <select name="question[kind]" class="select w-full mt-1">
              <option
                :for={kind <- Question.kinds()}
                value={kind}
                selected={@form[:kind].value == kind}
              >
                {Question.kind_label(kind)}
              </option>
            </select>
          </div>

          <.input
            field={@form[:prompt]}
            label="Question"
            placeholder="What eats the most time in a week?"
          />

          <%!-- Only the list kinds use options; a rating builds its own scale,
          and showing an empty options box next to one invites confusion. --%>
          <div :if={@form[:kind].value in ["choice", "multi"]}>
            <label class="text-sm font-medium">Options, one per line</label>
            <textarea name="question[options]" rows="6" class="textarea w-full mt-1">{@form[:options].value}</textarea>
            <p class="text-xs text-base-content/50 mt-1">
              Two to eight. A long list gets skipped — and if this is the first
              question, each option becomes a one-click link in the email.
            </p>
          </div>

          <p :if={@form[:kind].value in ["rating", "nps"]} class="text-xs text-base-content/50">
            {scale_note(@form[:kind].value)} Each number becomes a one-click link when
            this is the first question.
          </p>

          <p :if={@form[:kind].value == "text"} class="text-xs text-base-content/50">
            Free text can't be answered in one click, so the email carries a plain
            link to the survey instead.
          </p>

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={survey_path(assigns)} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Save question
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp scale_note("rating"), do: "Answered on a 1–5 scale."
  defp scale_note("nps"), do: "Answered 0–10, the standard recommend-score scale."
  defp scale_note(_), do: ""

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
