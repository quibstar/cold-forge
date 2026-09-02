defmodule ColdForge.Repo.Migrations.CreateCalls do
  use Ecto.Migration

  # Owner-operated contractors mostly do not publish an email address — six real
  # West Michigan roofing companies yielded one between them. They answer
  # phones. This is the same prospect list, worked down a channel that reaches
  # them.
  def change do
    alter table(:projects) do
      # The number to leave in a voicemail. A script that says "call me back"
      # without one is a wasted call.
      add :phone, :string
    end

    alter table(:prospects) do
      # Denormalised so "who do I call now" is one indexed query rather than a
      # join through every call ever made — the same reasoning as
      # `enrollments.next_send_at`.
      add :next_call_at, :utc_datetime
      add :last_called_at, :utc_datetime
      add :call_attempts, :integer, null: false, default: 0
      # Separate from the email suppression list because it is a different
      # request, but see `ColdForge.Calling` — asking not to be called stops
      # the email too.
      add :do_not_call, :boolean, null: false, default: false
    end

    create index(:prospects, [:project_id, :next_call_at])

    create table(:calls) do
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      # no_answer | voicemail | connected | interested | not_now |
      # not_interested | do_not_call | wrong_number
      add :outcome, :string, null: false
      # Which of the four voicemail scripts was left, so the next call knows
      # where in the cadence it is.
      add :voicemail_script, :integer
      add :notes, :text
      add :called_at, :utc_datetime, null: false
      # What the outcome scheduled, kept per call so the history shows what was
      # intended at the time rather than only where things ended up.
      add :next_call_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:calls, [:prospect_id])
    create index(:calls, [:called_at])
  end
end
