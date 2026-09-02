defmodule ColdForge.Survey.Response do
  @moduledoc """
  What one prospect answered.

  One column per answer shape rather than a single blob: the whole point of a
  survey is the tally, and counting in SQL beats loading every response to
  count them in Elixir.

  `message_id` records which send produced the answer, so the same question
  asked by two campaigns can still be read apart.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  schema "survey_responses" do
    field :choice, :string
    field :choices, {:array, :string}, default: []
    field :number, :integer
    field :text, :string
    field :answered_at, :utc_datetime

    belongs_to :question, ColdForge.Survey.Question, foreign_key: :survey_question_id
    belongs_to :prospect, ColdForge.Outreach.Prospect
    belongs_to :message, ColdForge.Outreach.Message

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(response, attrs) do
    response
    |> cast(attrs, [
      :survey_question_id,
      :prospect_id,
      :message_id,
      :choice,
      :choices,
      :number,
      :text,
      :answered_at
    ])
    |> validate_required([:survey_question_id, :prospect_id, :answered_at])
    |> validate_answered()
    |> unique_constraint([:survey_question_id, :prospect_id])
    |> foreign_key_constraint(:survey_question_id)
    |> foreign_key_constraint(:prospect_id)
  end

  @doc "Whether this row carries an actual answer rather than an empty submit."
  def answered?(%__MODULE__{} = response) do
    present?(response.choice) or response.choices != [] or
      not is_nil(response.number) or present?(response.text)
  end

  def answered?(attrs) when is_map(attrs) do
    present?(attrs[:choice]) or (attrs[:choices] || []) != [] or
      not is_nil(attrs[:number]) or present?(attrs[:text])
  end

  # A row with nothing in it is a form somebody skipped, not a data point.
  # Storing it would flatter the response rate.
  defp validate_answered(changeset) do
    if answered?(apply_changes(changeset)) do
      changeset
    else
      add_error(changeset, :choice, "pick something or write an answer")
    end
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
