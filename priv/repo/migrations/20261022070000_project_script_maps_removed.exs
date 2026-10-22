defmodule ColdForge.Repo.Migrations.ProjectScriptMapsRemoved do
  use Ecto.Migration

  # The two map columns the scripts used to live in. Their contents are rows in
  # `call_scripts` by now — `priv/repo/seeds/call_scripts.exs` moves them, and
  # it runs against an existing database before this.
  #
  # Separate from the migration that created the table so there is a point
  # between the two where both exist. Dropping a column in the same breath as
  # creating its replacement leaves no moment to check the copy worked, and
  # a column you dropped is not a thing you can go back and read.
  def up do
    alter table(:projects) do
      remove :call_scripts
      remove :voicemail_scripts
    end
  end

  def down do
    alter table(:projects) do
      add :call_scripts, :map, null: false, default: %{}
      add :voicemail_scripts, :map, null: false, default: %{}
    end
  end
end
