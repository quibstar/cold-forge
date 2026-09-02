defmodule ColdForgeWeb.SurveyQuestions do
  @moduledoc """
  The dynamic question rows, shared by creating and editing a survey.

  Shared deliberately: two copies of a form this fiddly drift, and the drift
  shows up as "it worked when I edited it but not when I created it".
  """
  use ColdForgeWeb, :html

  alias ColdForge.Survey.Question

  @doc """
  Rows driven by `cast_assoc`'s `sort_param`/`drop_param`.

  Each row posts its own `position` from its rendered index. Renumbering in the
  changeset instead — via `update_change(:questions, ...)` — looks tempting and
  raises: re-putting the relation's list re-runs Ecto's relation checks, and a
  child already marked `:replace` by `drop_param` trips them.
  """
  attr :form, :map, required: true

  def survey_questions(assigns) do
    ~H"""
    <.inputs_for :let={qf} field={@form[:questions]}>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <input type="hidden" name="survey[questions_order][]" value={qf.index} />
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

          <p :if={to_string(qf[:kind].value) == "text"} class="text-xs text-base-content/50 mt-2">
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
    """
  end

  # Options come back as a list once saved and as a raw string mid-edit, so the
  # textarea has to render both.
  defp options_text(value) when is_list(value), do: Enum.join(value, "\n")
  defp options_text(value) when is_binary(value), do: value
  defp options_text(_), do: ""

  defp scale_note("rating"), do: "Answered on a 1–5 scale."
  defp scale_note("nps"), do: "Answered 0–10, the standard recommend-score scale."
  defp scale_note(_), do: ""
end
