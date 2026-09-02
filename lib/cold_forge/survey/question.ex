defmodule ColdForge.Survey.Question do
  @moduledoc """
  One question in a survey.

  Five kinds, chosen to cover market research without turning into a survey
  builder:

    * `choice` — pick one from a list
    * `multi`  — pick any number from a list
    * `rating` — 1 to 5
    * `nps`    — 0 to 10, the standard recommend-score scale
    * `text`   — free text

  There is deliberately no branching. Conditional logic is where survey tools
  become complicated, and a cold email that opens with a three-question survey
  is already asking a lot — long ones don't get finished.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(choice multi rating nps text)

  schema "survey_questions" do
    field :position, :integer
    field :kind, :string, default: "choice"
    field :prompt, :string
    field :options, {:array, :string}, default: []

    belongs_to :survey, ColdForge.Survey.Survey
    has_many :responses, ColdForge.Survey.Response, foreign_key: :survey_question_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "Human label for a kind, for the admin's picker."
  def kind_label("choice"), do: "Pick one"
  def kind_label("multi"), do: "Pick any"
  def kind_label("rating"), do: "Rating, 1–5"
  def kind_label("nps"), do: "Recommend score, 0–10"
  def kind_label("text"), do: "Free text"
  def kind_label(other), do: other

  @doc "Whether the kind draws its answers from `options`."
  def listed?(%__MODULE__{kind: kind}), do: kind in ~w(choice multi)

  @doc "Whether more than one answer may be given."
  def multiple?(%__MODULE__{kind: "multi"}), do: true
  def multiple?(%__MODULE__{}), do: false

  @doc """
  The numeric scale for `rating` and `nps`, or `nil`.

  NPS starts at 0 rather than 1 — a zero is a meaningful answer on that scale,
  and shifting it would quietly change what the number means.
  """
  def scale(%__MODULE__{kind: "rating"}), do: 1..5
  def scale(%__MODULE__{kind: "nps"}), do: 0..10
  def scale(%__MODULE__{}), do: nil

  @doc """
  The answers that can be offered as one-click links in an email, as strings.

  Only kinds with a small fixed set qualify. `multi` is excluded even though it
  has options: one click can't express "these three", and pretending otherwise
  would record a single choice as if it were the whole answer.
  """
  def clickable_answers(%__MODULE__{kind: "choice"} = question), do: question.options

  def clickable_answers(%__MODULE__{kind: kind} = question) when kind in ~w(rating nps) do
    question |> scale() |> Enum.map(&to_string/1)
  end

  def clickable_answers(%__MODULE__{}), do: []

  @doc false
  def changeset(question, attrs) do
    question
    |> cast(split_options(attrs), [:survey_id, :position, :kind, :prompt, :options])
    |> update_change(:options, &clean_options/1)
    |> validate_required([:survey_id, :position, :prompt])
    |> validate_inclusion(:kind, @kinds)
    |> validate_options()
    |> unique_constraint([:survey_id, :position])
    |> foreign_key_constraint(:survey_id)
  end

  # A pick-one with nothing to pick from renders an empty question in somebody's
  # inbox, which is worse than no question.
  defp validate_options(changeset) do
    kind = get_field(changeset, :kind)
    options = get_field(changeset, :options) || []

    cond do
      kind in ~w(choice multi) and length(options) < 2 ->
        add_error(changeset, :options, "needs at least two options")

      kind in ~w(choice multi) and length(options) > 8 ->
        add_error(changeset, :options, "keep it to eight or fewer — a long list gets skipped")

      true ->
        changeset
    end
  end

  # Options arrive from a textarea as one string, newline separated. `cast/3`
  # refuses a plain string for an array field, so the split has to happen before
  # it — doing it in `update_change` is too late, since the value never lands.
  defp split_options(attrs) when is_map(attrs) do
    case fetch_options(attrs) do
      {key, value} when is_binary(value) -> Map.put(attrs, key, String.split(value, "\n"))
      _ -> attrs
    end
  end

  defp split_options(attrs), do: attrs

  defp fetch_options(attrs) do
    cond do
      Map.has_key?(attrs, "options") -> {"options", attrs["options"]}
      Map.has_key?(attrs, :options) -> {:options, attrs[:options]}
      true -> nil
    end
  end

  # A blank line is the operator hitting return, not an empty option.
  defp clean_options(options) when is_list(options) do
    options |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp clean_options(_), do: []
end
