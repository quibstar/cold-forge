defmodule ColdForge.Repo.Migrations.AddCampaignToSourcingSources do
  use Ecto.Migration

  # The drip a source's new finds go into when "Add all and start" is clicked.
  def change do
    alter table(:sourcing_sources) do
      add :campaign_id, references(:campaigns, type: :uuid, on_delete: :nilify_all)
    end

    create index(:sourcing_sources, [:campaign_id])
  end
end
