defmodule ColdForge.Repo.Migrations.CreateOutreachAndSurveys do
  @moduledoc """
  The whole domain in one migration.

  This app has never been deployed, so its schema has no history worth
  preserving — the migrations this replaces were an afternoon of renames and
  second thoughts about tables nobody outside this laptop has ever seen. Keys
  are UUIDv7 throughout; see `ColdForge.UUIDv7` for why version 7.
  """
  use Ecto.Migration

  def change do
    ## Projects — one idea each: sender identity, landing page, branding.

    create table(:projects) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :from_name, :string, null: false
      add :from_email, :citext, null: false
      add :reply_to, :citext
      add :landing_url, :string
      # CAN-SPAM requires a real postal address in every commercial email.
      add :postal_address, :text
      # Fallback for {{industry}} when a prospect's own is blank.
      add :industry, :string
      # The sign-off appended above the compliance footer. In cold mail this is
      # the branding that works; the logo and colour feed the optional HTML
      # wrapper, which is off by default.
      add :signature, :text
      add :logo_url, :string
      add :logo_path, :string
      add :brand_color, :string
      add :timezone, :string, null: false, default: "America/New_York"
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:slug])

    ## Prospects — the pool campaigns draw from.

    create table(:prospects) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :first_name, :string
      add :last_name, :string
      add :company, :string
      add :title, :string
      add :industry, :string
      add :phone, :string
      add :website, :string
      # Imported columns nobody mapped, still reachable from a merge tag.
      add :custom_fields, :map, null: false, default: %{}
      add :source, :string
      add :notes, :text
      add :status, :string, null: false, default: "new"
      add :unsubscribed_at, :utc_datetime
      add :bounced_at, :utc_datetime
      add :replied_at, :utc_datetime
      # Stable per person, so the unsubscribe link in *any* message for them
      # resolves without a message lookup. Random rather than derived from the
      # id: a UUIDv7 leaks its creation time and must never stand in for a
      # secret.
      add :unsubscribe_token, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # The same person may be a prospect for two ideas, so email is unique per
    # project rather than globally.
    create unique_index(:prospects, [:project_id, :email])
    create unique_index(:prospects, [:unsubscribe_token])
    create index(:prospects, [:project_id, :status])

    ## Suppression — global, not per project. Someone who opts out of one idea
    ## should never surface in the next one's list.

    create table(:suppressions) do
      add :email, :citext, null: false
      add :reason, :string, null: false
      add :notes, :text
      add :project_id, references(:projects, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:suppressions, [:email])

    ## Surveys — owned by the project rather than a campaign, so the same
    ## question asked by several campaigns yields one comparable result set.

    create table(:surveys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :intro, :text
      add :thank_you, :text

      timestamps(type: :utc_datetime)
    end

    create index(:surveys, [:project_id])

    create table(:survey_questions) do
      add :survey_id, references(:surveys, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      # choice | multi | rating | nps | text
      add :kind, :string, null: false, default: "choice"
      add :prompt, :string, null: false
      # Empty for the numeric and free-text kinds.
      add :options, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:survey_questions, [:survey_id, :position])

    ## Campaigns — emails plus the people who get them. One email with no delay
    ## is a single send; several with delays are follow-ups. There is no kind.

    create table(:campaigns) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "draft"
      # Wraps the body in a branded HTML shell. Off by default: a designed
      # template is the clearest "sent in bulk" signal there is.
      add :branded, :boolean, null: false, default: false
      # Answering is engagement; chasing somebody who just told you something is
      # the own-goal the survey exists to avoid.
      add :stop_on_answer, :boolean, null: false, default: true
      # Sending window, in the project's timezone.
      add :send_window_start, :integer, null: false, default: 8
      add :send_window_end, :integer, null: false, default: 17
      # ISO day numbers, 1 = Monday.
      add :send_days, {:array, :integer}, null: false, default: [1, 2, 3, 4, 5]
      add :daily_cap, :integer, null: false, default: 50

      timestamps(type: :utc_datetime)
    end

    create index(:campaigns, [:project_id])

    create table(:campaign_steps) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      # Days after the previous email. The first is always 0.
      add :delay_days, :integer, null: false, default: 0
      add :subject, :string, null: false
      add :body, :text, null: false
      # Which survey {{survey}} renders here. On the email rather than the
      # campaign so a follow-up can ask something different.
      add :survey_id, references(:surveys, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:campaign_steps, [:campaign_id, :position])

    ## Enrollments — one person's progress through one campaign.

    create table(:enrollments) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :current_position, :integer, null: false, default: 0
      add :next_send_at, :utc_datetime
      add :stopped_reason, :string
      add :completed_at, :utc_datetime
      # Denormalised so the scheduler can skip an answered enrollment without
      # joining through surveys on every pass.
      add :answered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Re-adding a CSV must not double-send.
    create unique_index(:enrollments, [:campaign_id, :prospect_id])
    # The scheduler's hot path.
    create index(:enrollments, [:status, :next_send_at])

    ## Messages — one row per email we tried to send, storing the rendered text
    ## as it went out so what a person saw survives later edits to the email.

    create table(:messages) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :enrollment_id, references(:enrollments, on_delete: :delete_all)
      add :campaign_step_id, references(:campaign_steps, on_delete: :nilify_all)
      add :subject, :string, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :sent_at, :utc_datetime
      add :failed_at, :utc_datetime
      add :error, :text
      add :provider_message_id, :string
      add :open_token, :string, null: false
      add :first_opened_at, :utc_datetime
      add :open_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:messages, [:open_token])
    create index(:messages, [:project_id, :status])
    create index(:messages, [:prospect_id])
    create index(:messages, [:enrollment_id])

    ## Tracked links — the token is what appears in the email, so the recipient
    ## never sees the destination and every click ties to one send.

    create table(:tracked_links) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :destination_url, :text, null: false
      add :label, :string
      add :click_count, :integer, null: false, default: 0
      add :first_clicked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tracked_links, [:token])
    create index(:tracked_links, [:message_id])

    create table(:link_clicks) do
      add :tracked_link_id, references(:tracked_links, on_delete: :delete_all), null: false
      add :ip, :string
      add :user_agent, :text
      add :clicked_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:link_clicks, [:tracked_link_id])

    ## Survey answers.

    create table(:survey_responses) do
      add :survey_question_id, references(:survey_questions, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :nilify_all)
      # One column per answer shape rather than a blob: the point of a survey is
      # the tally, and counting in SQL beats loading every row to count it.
      add :choice, :string
      add :choices, {:array, :string}, null: false, default: []
      add :number, :integer
      add :text, :text
      add :answered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # Changing your mind corrects the record rather than adding a second point.
    create unique_index(:survey_responses, [:survey_question_id, :prospect_id])
    create index(:survey_responses, [:prospect_id])

    ## Survey links — the one-click hop from an email. With a choice it
    ## pre-selects that answer; without one, the survey opens blank.

    create table(:survey_links) do
      add :token, :string, null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :survey_question_id, references(:survey_questions, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :choice, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:survey_links, [:token])
    create index(:survey_links, [:message_id])
  end
end
