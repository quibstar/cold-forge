defmodule ColdForge.Repo.Migrations.CampaignMergeDefaults do
  use Ecto.Migration

  # A campaign usually targets one segment — that's what makes the copy work —
  # so the campaign is the natural place to say "everyone here is a roofer".
  #
  # A map rather than an `industry` column, because the next variable would want
  # a column too, and the one after that. One concept covers all of them, and it
  # reuses the editor prospects already have for their extra fields.
  def change do
    alter table(:campaigns) do
      add :merge_defaults, :map, null: false, default: %{}
    end

    # Superseded: a campaign-level default is both more precise and easier to
    # find than a project-wide one.
    alter table(:projects) do
      remove :industry, :string
    end
  end
end
