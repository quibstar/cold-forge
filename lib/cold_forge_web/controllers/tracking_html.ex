defmodule ColdForgeWeb.TrackingHTML do
  @moduledoc """
  The unsubscribe pages.

  These render standalone — no app layout, no nav, no branding beyond the
  project name. Someone who wants out should see one button, not a website.
  """
  use ColdForgeWeb, :html

  embed_templates "tracking_html/*"

  @doc """
  Whether an option should start selected.

  What they already answered wins over what they clicked, so coming back to
  change your mind shows the current state rather than resetting to the link.
  """
  def chosen?(question, option, link, responses) do
    case Map.get(responses, question.id) do
      %{choice: choice} when is_binary(choice) and choice != "" ->
        choice == option

      %{choices: choices} when choices != [] ->
        option in choices

      _ ->
        question.id == link.survey_question_id and link.choice == option
    end
  end

  @doc "Whether a point on a numeric scale should start selected."
  def numbered?(question, number, link, responses) do
    case Map.get(responses, question.id) do
      %{number: answered} when is_integer(answered) ->
        answered == number

      _ ->
        question.id == link.survey_question_id and link.choice == to_string(number)
    end
  end

  @doc "Free text already given, so the box isn't blanked when they return."
  def answered_text(question, responses) do
    case Map.get(responses, question.id) do
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end
  end

  def scale_values(question), do: Enum.to_list(ColdForge.Survey.Question.scale(question) || [])

  def low_label(%{kind: "nps"}), do: "Not at all likely"
  def low_label(_), do: "Poor"

  def high_label(%{kind: "nps"}), do: "Extremely likely"
  def high_label(_), do: "Great"

  @doc """
  Centered card shared by all three unsubscribe states, so the page a recipient
  lands on looks the same whether the link worked or not.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def unsub_shell(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 flex items-center justify-center px-4 py-12">
      <div class="w-full max-w-md">
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h1 class="text-xl font-semibold">{@title}</h1>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>
    """
  end
end
