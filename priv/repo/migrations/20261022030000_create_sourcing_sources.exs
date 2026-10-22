defmodule ColdForge.Repo.Migrations.CreateSourcingSources do
  use Ecto.Migration

  # A saved search. You make one per thing you are selling — "ExteriorPro, West
  # Michigan" — point it at the project its prospects belong to, give it the
  # trades and the towns, and run it.
  #
  # Before this, parameters lived nowhere and there was no way to start a
  # search at all: discovery existed as modules nobody could invoke. And the
  # project was chosen row by row at promotion time, which is the wrong moment
  # — you know which project a search is for when you set it up, not three
  # hundred rows later.
  def change do
    create table(:sourcing_sources, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :name, :string, null: false
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false

      # Which discovery module runs: places | overpass | irs_bmf | license_csv.
      add :provider, :string, null: false, default: "places"
      # What to look for, and where. For Places a locality is "Grand Rapids,
      # MI"; for Overpass it is a state ISO code like "US-MI".
      add :segments, {:array, :string}, null: false, default: []
      add :localities, {:array, :string}, null: false, default: []

      add :active, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      add :last_run_summary, :map, null: false, default: %{}
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:sourcing_sources, [:project_id])
    create unique_index(:sourcing_sources, [:name])

    alter table(:sourcing_orgs) do
      # Which saved search turned this up. Nullable because rows can still be
      # seeded by hand, and because the three from the first end-to-end run
      # predate sources existing.
      add :source_id, references(:sourcing_sources, type: :uuid, on_delete: :nilify_all)
    end

    create index(:sourcing_orgs, [:source_id])

    # `source` on an org was already the provider name, which collides with a
    # source now being a record. Rename it so the two ideas have two words.
    rename table(:sourcing_orgs), :source, to: :provider
  end
end
