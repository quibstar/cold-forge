defmodule ColdForge.Repo.Migrations.AddFlyersToMarkets do
  use Ecto.Migration

  # A campaign can say something different on its flyers and postcards than
  # the rest of the project: its own flyer content (empty means "use the
  # project's"), and its placements and cards marked as its own so a print or
  # a scan uses that campaign's words and landing page.
  def change do
    alter table(:markets) do
      add :flyer, :map
    end

    alter table(:flyer_placements) do
      add :market_id, references(:markets, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:postcards) do
      add :market_id, references(:markets, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:flyer_placements, [:market_id])
    create index(:postcards, [:market_id])
  end
end
