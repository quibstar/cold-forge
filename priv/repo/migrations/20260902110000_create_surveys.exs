defmodule ColdForge.Repo.Migrations.CreateSurveys do
  use Ecto.Migration

  # A survey was owned by one campaign, which meant the same question asked by
  # two campaigns produced two unrelated result sets. For market research that
  # is the wrong way round: asking one question across many campaigns and
  # comparing the answers is the point. So a survey belongs to the project and
  # an email links to one.
  def up do
    create table(:surveys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # Shown above the questions on the answer page. The email got them to
      # click; this is the one line explaining what they clicked into.
      add :intro, :text
      add :thank_you, :text

      timestamps(type: :utc_datetime)
    end

    create index(:surveys, [:project_id])

    alter table(:survey_questions) do
      add :survey_id, references(:surveys, on_delete: :delete_all)
    end

    alter table(:campaign_steps) do
      # Which survey this email asks, if any. On the email rather than the
      # campaign so a follow-up can ask something different.
      add :survey_id, references(:surveys, on_delete: :nilify_all)
    end

    flush()

    # Backfill: one survey per campaign that already had questions, so nothing
    # written before this migration is orphaned.
    execute("""
    INSERT INTO surveys (project_id, name, inserted_at, updated_at)
    SELECT DISTINCT c.project_id,
           c.name || ' survey',
           NOW() AT TIME ZONE 'utc',
           NOW() AT TIME ZONE 'utc'
    FROM campaigns c
    JOIN survey_questions q ON q.campaign_id = c.id
    """)

    execute("""
    UPDATE survey_questions q
    SET survey_id = s.id
    FROM campaigns c
    JOIN surveys s ON s.project_id = c.project_id AND s.name = c.name || ' survey'
    WHERE q.campaign_id = c.id
    """)

    # Point each campaign's first email at its backfilled survey, so an existing
    # {{survey}} tag keeps rendering.
    execute("""
    UPDATE campaign_steps st
    SET survey_id = q.survey_id
    FROM survey_questions q
    WHERE q.campaign_id = st.campaign_id AND st.position = 1
    """)

    # Now that questions hang off surveys, the campaign link is redundant — and
    # keeping it would let the two disagree.
    drop index(:survey_questions, [:campaign_id, :position])

    alter table(:survey_questions) do
      remove :campaign_id
      modify :survey_id, :bigint, null: false
    end

    create unique_index(:survey_questions, [:survey_id, :position])
  end

  def down do
    drop index(:survey_questions, [:survey_id, :position])

    alter table(:survey_questions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all)
    end

    create unique_index(:survey_questions, [:campaign_id, :position])

    alter table(:campaign_steps) do
      remove :survey_id
    end

    alter table(:survey_questions) do
      remove :survey_id
    end

    drop table(:surveys)
  end
end
