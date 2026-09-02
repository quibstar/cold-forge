defmodule ColdForge.Repo.Migrations.ProjectMergeDefaults do
  use Ecto.Migration

  # The same "default values" map at the project level, as the broadest
  # fallback: things true of every campaign for an idea — who you sell to, what
  # you call the product — belong once on the project rather than copied into
  # each campaign.
  def change do
    alter table(:projects) do
      add :merge_defaults, :map, null: false, default: %{}
    end
  end
end
