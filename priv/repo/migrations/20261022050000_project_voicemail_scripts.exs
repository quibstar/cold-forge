defmodule ColdForge.Repo.Migrations.ProjectVoicemailScripts do
  use Ecto.Migration

  # The four numbered voicemails, overridable per project.
  #
  # They were written into `ColdForge.Calling.Scripts` as Elixir, which was
  # fine while they were the only scripts in the app. Now that everything else
  # a caller reads is a template on the project, a message you can only change
  # by editing source and deploying is the odd one out — and these are the ones
  # that get reworded most, because a voicemail that isn't landing is obvious
  # within a day of dialling.
  #
  # Keyed "1" to "4". A project with nothing here falls back to the built-in
  # wording, so a new project has four working messages without setup and only
  # the ones actually changed are stored.
  def change do
    alter table(:projects) do
      add :voicemail_scripts, :map, null: false, default: %{}
    end
  end
end
