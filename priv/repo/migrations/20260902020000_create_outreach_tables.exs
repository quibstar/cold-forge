defmodule ColdForge.Repo.Migrations.CreateOutreachTables do
  use Ecto.Migration

  def change do
    # A project is one idea/product: its own sender identity, its own landing
    # page, its own prospects. Everything else in the schema hangs off one.
    create table(:projects) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :from_name, :string, null: false
      add :from_email, :citext, null: false
      add :reply_to, :citext
      # Where a tracked link sends someone by default — e.g. the ExteriorPro
      # demo form. Steps may override it per link.
      add :landing_url, :string
      # CAN-SPAM requires a real postal address in every commercial email.
      add :postal_address, :text
      add :timezone, :string, null: false, default: "America/New_York"
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:slug])

    create table(:prospects) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :first_name, :string
      add :last_name, :string
      add :company, :string
      add :title, :string
      add :phone, :string
      add :website, :string
      # Extra merge-tag values that don't deserve their own column.
      add :custom_fields, :map, null: false, default: %{}
      add :source, :string
      add :notes, :text
      add :status, :string, null: false, default: "new"
      add :unsubscribed_at, :utc_datetime
      add :bounced_at, :utc_datetime
      add :replied_at, :utc_datetime
      # Stable per-prospect token so the unsubscribe link in *any* message for
      # this person resolves without a message lookup.
      add :unsubscribe_token, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # The same person may be a prospect for two different ideas, so email is
    # unique per project rather than globally.
    create unique_index(:prospects, [:project_id, :email])
    create unique_index(:prospects, [:unsubscribe_token])
    create index(:prospects, [:project_id, :status])

    # Global, not per-project: if somebody asks to be left alone, that applies
    # to every idea I ever have — not just the one that emailed them.
    create table(:suppressions) do
      add :email, :citext, null: false
      add :reason, :string, null: false
      add :notes, :text
      add :project_id, references(:projects, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:suppressions, [:email])

    create table(:sequences) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "draft"
      # Sending window, in the project's timezone. Cold mail sent at 3am reads
      # as automation.
      add :send_window_start, :integer, null: false, default: 8
      add :send_window_end, :integer, null: false, default: 17
      # ISO day numbers (1 = Monday). Weekdays by default.
      add :send_days, {:array, :integer}, null: false, default: [1, 2, 3, 4, 5]
      add :daily_cap, :integer, null: false, default: 50

      timestamps(type: :utc_datetime)
    end

    create index(:sequences, [:project_id])

    create table(:sequence_steps) do
      add :sequence_id, references(:sequences, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      # Days to wait after the previous step. Step 1 is always 0.
      add :delay_days, :integer, null: false, default: 0
      add :subject, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sequence_steps, [:sequence_id, :position])

    create table(:enrollments) do
      add :sequence_id, references(:sequences, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :current_position, :integer, null: false, default: 0
      add :next_send_at, :utc_datetime
      add :stopped_reason, :string
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One enrollment per prospect per sequence — re-adding a CSV shouldn't
    # double-send.
    create unique_index(:enrollments, [:sequence_id, :prospect_id])
    # The scheduler's hot path: find active enrollments that are due.
    create index(:enrollments, [:status, :next_send_at])

    create table(:messages) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      add :enrollment_id, references(:enrollments, on_delete: :delete_all)
      add :sequence_step_id, references(:sequence_steps, on_delete: :nilify_all)
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

    # One row per (message, destination). The token is what actually appears in
    # the email, so the recipient never sees the destination URL directly and
    # every click is attributable to a specific send.
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
  end
end
