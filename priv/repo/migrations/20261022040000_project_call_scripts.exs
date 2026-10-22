defmodule ColdForge.Repo.Migrations.ProjectCallScripts do
  use Ecto.Migration

  # The call scripts, written once per project instead of copied onto every
  # prospect.
  #
  # They arrived from ExteriorPro as six text fields on each prospect, which is
  # how they had been generated: a sheet per script, one row per company, the
  # company and the town pasted in. 112 prospects, four fields each, 544KB —
  # and `objections` had four distinct values across the whole list, while
  # `problem_question` had nine. The same paragraphs, stored a hundred times.
  #
  # A script is a template with the prospect's details read into it, so that is
  # what it is now: `{{company}}`, `{{city}}`, `{{industry}}`, rendered by the
  # same `ColdForge.Sending.Renderer` the emails use — one tag syntax to learn,
  # and a change to the opener is one edit rather than 112.
  #
  # A prospect's own `custom_fields` still wins where it has one, so a shop that
  # genuinely needs its own wording can have it. Nothing fills those by default.
  def change do
    alter table(:projects) do
      add :call_scripts, :map, null: false, default: %{}
    end
  end
end
