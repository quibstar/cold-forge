defmodule ColdForge.Repo.Migrations.AddPurposeToSourcingSources do
  use Ecto.Migration

  # What a search's results are for: prospects to call and email, or places
  # to put up flyers. A search for supply houses is the second kind, and its
  # results must never land in the drip or the call list as if they were
  # customers.
  def change do
    alter table(:sourcing_sources) do
      add :purpose, :string, null: false, default: "prospects"
    end
  end
end
