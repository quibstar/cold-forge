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
    |> assign(:previewing, false)
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
  def handle_event("preview", _params, socket) do
    {:noreply, assign(socket, :previewing, true)}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :previewing, false)}
  end

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
        <button :if={@questions != []} phx-click="preview" class="btn btn-sm">
          <.icon name="hero-eye" class="size-4" /> Preview
        </button>
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

    <%!-- An iframe onto the real answer page rather than a re-drawn copy: a
    preview that renders its own version of the page is a preview of nothing,
    because it drifts the moment the real one changes. --%>
    <div
      :if={@previewing}
      class="fixed inset-0 z-[60] flex items-start justify-center p-4 sm:pt-[6vh]"
    >
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" phx-click="close_preview" />
      <div
        class="relative w-full max-w-2xl card bg-base-100 shadow-xl"
        phx-window-keydown="close_preview"
        phx-key="Escape"
      >
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">What they see after clicking</h2>
            <button phx-click="close_preview" class="btn btn-sm btn-circle" aria-label="Close">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <iframe
            title="Survey preview"
            src={~p"/admin/p/#{@project_id}/surveys/#{@survey_id}/preview"}
            class="w-full h-[32rem] rounded-lg border border-base-300 bg-base-200"
          ></iframe>
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

      <%!-- Dynamic rows through `sort_param`/`drop_param`: the hidden ordering
      input carries each row's index, so a question can be added or removed
      without a round trip per question — and the list itself is the order,
      which is why positions are renumbered from it on save. --%>
      <.inputs_for :let={qf} field={@form[:questions]}>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <input type="hidden" name="survey[questions_order][]" value={qf.index} />
            <%!-- Position comes from the row's own index rather than being
            renumbered in the changeset, which can't be done without re-putting
            the relation and tripping Ecto's replace checks. --%>
            <input type="hidden" name={qf[:position].name} value={qf.index + 1} />

            <div class="flex items-center justify-between gap-3">
              <span class="badge badge-sm badge-ghost">
                {if qf.index == 0, do: "asked in the email", else: "asked on the answer page"}
              </span>
              <label class="btn btn-xs btn-ghost text-error cursor-pointer">
                <input
                  type="checkbox"
                  name="survey[questions_delete][]"
                  value={qf.index}
                  class="hidden"
                /> Remove
              </label>
            </div>

            <div class="grid gap-4 sm:grid-cols-3 mt-2">
              <div>
                <label class="text-sm font-medium">Answer type</label>
                <select name={qf[:kind].name} class="select w-full mt-1">
                  <option
                    :for={kind <- Question.kinds()}
                    value={kind}
                    selected={to_string(qf[:kind].value) == kind}
                  >
                    {Question.kind_label(kind)}
                  </option>
                </select>
              </div>
              <div class="sm:col-span-2">
                <.input field={qf[:prompt]} label="Question" placeholder="What eats the most time?" />
              </div>
            </div>

            <%!-- Only the list kinds use options; a rating builds its own scale,
            and an empty options box beside one invites confusion. --%>
            <div :if={to_string(qf[:kind].value) in ["choice", "multi"]} class="mt-2">
              <label class="text-sm font-medium">Options, one per line</label>
              <textarea name={qf[:options].name} rows="5" class="textarea w-full mt-1">{options_text(qf[:options].value)}</textarea>
              <p class="text-xs text-base-content/50 mt-1">
                Two to eight. If this is the first question, each option becomes a
                one-click link in the email.
              </p>
            </div>

            <p
              :if={to_string(qf[:kind].value) in ["rating", "nps"]}
              class="text-xs text-base-content/50 mt-2"
            >
              {scale_note(to_string(qf[:kind].value))} Each number becomes a one-click
              link when this is the first question.
            </p>

            <p
              :if={to_string(qf[:kind].value) == "text"}
              class="text-xs text-base-content/50 mt-2"
            >
              Free text can't be answered in one click, so the email carries a plain
              link to the survey instead.
            </p>
          </div>
        </div>
      </.inputs_for>

      <label class="btn btn-outline w-full cursor-pointer">
        <input type="checkbox" name="survey[questions_order][]" class="hidden" />
        <.icon name="hero-plus" class="size-4" /> Add a question
      </label>

      <div class="flex justify-end gap-2">
        <.link navigate={survey_path(assigns)} class="btn btn-ghost">Cancel</.link>
        <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
          Save survey
        </button>
      </div>
    </.form>
    """
  end

  # Options come back as a list once saved and as a raw string mid-edit, so the
  # textarea has to render both.
  defp options_text(value) when is_list(value), do: Enum.join(value, "\n")
  defp options_text(value) when is_binary(value), do: value
  defp options_text(_), do: ""

  # Positions order the questions but need not be a dense 1..n run — deleting a
  # row can leave a gap until the next save. "First" is therefore first in the
  # ordered list, not position 1.
  defp first?(question, questions), do: question.id == List.first(questions).id

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
