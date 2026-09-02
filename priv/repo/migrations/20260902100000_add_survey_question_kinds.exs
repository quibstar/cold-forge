defmodule ColdForge.Repo.Migrations.AddSurveyQuestionKinds do
  use Ecto.Migration

  def change do
    alter table(:survey_questions) do
      # choice | multi | rating | nps | text
      add :kind, :string, null: false, default: "choice"
    end

    alter table(:survey_responses) do
      # Explicit columns per answer shape rather than one jsonb blob: the whole
      # point of a survey is the tally, and tallying in SQL beats loading every
      # response to count them in Elixir.
      add :choices, {:array, :string}, null: false, default: []
      add :number, :integer
    end
  end
end
