defmodule ColdForge.Repo.Migrations.CreateMarkets do
  use Ecto.Migration

  # A campaign, in the screens' words: one push inside a project — "Michigan",
  # "Grand Rapids", "Dog breeders, Texas" — that its searches and email
  # sequences belong to. Everything else (people, calls, postcards, replies)
  # is reached through those two, so only they carry the key.
  def change do
    create table(:markets) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:markets, [:project_id])

    # Deleting a campaign leaves its searches and sequences in the project, just
    # not in any campaign: sending must never stop because a label went away.
    alter table(:campaigns) do
      add :market_id, references(:markets, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:sourcing_sources) do
      add :market_id, references(:markets, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:campaigns, [:market_id])
    create index(:sourcing_sources, [:market_id])
  end
end
