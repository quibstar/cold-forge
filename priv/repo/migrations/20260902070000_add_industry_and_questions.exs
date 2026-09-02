defmodule ColdForge.Repo.Migrations.AddIndustryAndQuestions do
  use Ecto.Migration

  def change do
    alter table(:prospects) do
      # First-class rather than left in custom_fields: industry is the thing you
      # segment a campaign by, so it wants a column you can filter on.
      add :industry, :string
    end

    alter table(:projects) do
      # Fallback for {{industry}} when a prospect's is blank — "contractors"
      # reads better than nothing, and better than a raw tag.
      add :industry, :string
    end

    alter table(:campaigns) do
      # Answering is engagement. Continuing to send follow-ups to somebody who
      # just told you something is the classic cold-email own-goal.
      add :stop_on_answer, :boolean, null: false, default: true
    end

    create table(:campaign_questions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :prompt, :string, null: false
      # Empty for a free-text question; the answer page renders a textarea.
      add :options, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:campaign_questions, [:campaign_id, :position])

    create table(:question_responses) do
      add :campaign_question_id, references(:campaign_questions, on_delete: :delete_all),
        null: false

      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :nilify_all)
      add :choice, :string
      add :text, :text
      add :answered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One answer per person per question — coming back to change your mind
    # should correct the record, not add a second data point.
    create unique_index(:question_responses, [:campaign_question_id, :prospect_id])
    create index(:question_responses, [:prospect_id])

    # The one-click hop from the email. Each row is a specific person answering
    # a specific question a specific way, so the landing page can pre-select
    # without asking who they are.
    create table(:answer_links) do
      add :token, :string, null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false

      add :campaign_question_id, references(:campaign_questions, on_delete: :delete_all),
        null: false

      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :choice, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:answer_links, [:token])
    create index(:answer_links, [:message_id])

    alter table(:enrollments) do
      # Denormalised so the scheduler can skip an answered enrollment without
      # joining through questions on every pass.
      add :answered_at, :utc_datetime
    end
  end
end
