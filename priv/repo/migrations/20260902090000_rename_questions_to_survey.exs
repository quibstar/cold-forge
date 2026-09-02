defmodule ColdForge.Repo.Migrations.RenameQuestionsToSurvey do
  use Ecto.Migration

  # A campaign's questions are a survey — that's what it is and what it gets
  # called, so the tables say so too. Renamed rather than dropped and recreated
  # because there is already data in them.
  def up do
    rename table(:campaign_questions), to: table(:survey_questions)
    rename table(:question_responses), to: table(:survey_responses)
    rename table(:answer_links), to: table(:survey_links)

    rename table(:survey_responses), :campaign_question_id, to: :survey_question_id
    rename table(:survey_links), :campaign_question_id, to: :survey_question_id

    rename_objects(:up)
  end

  def down do
    rename_objects(:down)

    rename table(:survey_links), :survey_question_id, to: :campaign_question_id
    rename table(:survey_responses), :survey_question_id, to: :campaign_question_id

    rename table(:survey_links), to: table(:answer_links)
    rename table(:survey_responses), to: table(:question_responses)
    rename table(:survey_questions), to: table(:campaign_questions)
  end

  @index_renames [
    {"campaign_questions_pkey", "survey_questions_pkey"},
    {"campaign_questions_campaign_id_position_index",
     "survey_questions_campaign_id_position_index"},
    {"question_responses_pkey", "survey_responses_pkey"},
    {"question_responses_campaign_question_id_prospect_id_index",
     "survey_responses_survey_question_id_prospect_id_index"},
    {"question_responses_prospect_id_index", "survey_responses_prospect_id_index"},
    {"answer_links_pkey", "survey_links_pkey"},
    {"answer_links_token_index", "survey_links_token_index"},
    {"answer_links_message_id_index", "survey_links_message_id_index"}
  ]

  # Foreign keys are constraints, not indexes — ALTER INDEX reports
  # "does not exist, skipping" on them and leaves the old name behind.
  @constraint_renames [
    {"survey_questions", "campaign_questions_campaign_id_fkey",
     "survey_questions_campaign_id_fkey"},
    {"survey_responses", "question_responses_campaign_question_id_fkey",
     "survey_responses_survey_question_id_fkey"},
    {"survey_responses", "question_responses_prospect_id_fkey",
     "survey_responses_prospect_id_fkey"},
    {"survey_responses", "question_responses_message_id_fkey",
     "survey_responses_message_id_fkey"},
    {"survey_links", "answer_links_message_id_fkey", "survey_links_message_id_fkey"},
    {"survey_links", "answer_links_campaign_question_id_fkey",
     "survey_links_survey_question_id_fkey"},
    {"survey_links", "answer_links_prospect_id_fkey", "survey_links_prospect_id_fkey"}
  ]

  defp rename_objects(direction) do
    for {old, new} <- @index_renames do
      {from, to} = if direction == :up, do: {old, new}, else: {new, old}
      execute("ALTER INDEX IF EXISTS #{from} RENAME TO #{to}")
    end

    for {table, old, new} <- @constraint_renames do
      {from, to} = if direction == :up, do: {old, new}, else: {new, old}
      execute("ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to}")
    end
  end
end
