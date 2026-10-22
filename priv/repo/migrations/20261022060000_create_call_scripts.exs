defmodule ColdForge.Repo.Migrations.CreateCallScripts do
  use Ecto.Migration

  # Scripts and voicemails as rows, so there can be as many as the work needs.
  #
  # They were two map columns on `projects` with fixed keys — three scripts,
  # four voicemails, and no way to add a fifth or throw one out. That shape
  # came from ExteriorPro, where a generator wrote a spreadsheet column per
  # section; it was never a decision about how many scripts somebody should be
  # allowed to have.
  #
  # One table rather than two because they are the same thing twice: a
  # template with merge tags in it, read with one prospect's details. `kind`
  # says which list it belongs to and `position` orders it — for a voicemail
  # that is also its number in the cadence, which is what
  # `calls.voicemail_script` records.
  #
  # The map columns stay until `ProjectScriptMapsRemoved` drops them, so the
  # rows can be written from them first rather than this migration guessing at
  # UUIDs and concatenation in SQL.
  def change do
    create table(:call_scripts) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :body, :text, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:call_scripts, [:project_id, :kind])

    # Two voicemails numbered 3 would make "which do I leave next" ambiguous,
    # and the answer is recorded on every call row.
    create unique_index(:call_scripts, [:project_id, :kind, :position])
  end
end
