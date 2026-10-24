defmodule ColdForge.Repo.Migrations.RecordWhetherAPromotionCreatedAProspect do
  use Ecto.Migration

  # "Added" counted organisations, which is not the same as prospects gained:
  # Places lists a company once per location, so several rows can promote onto
  # one prospect. Recording which happened makes the tab's number readable.
  #
  # Rows promoted before this are left null on purpose. Which org of a group
  # created the shared prospect isn't recoverable, and guessing would put a
  # wrong answer somewhere it looks authoritative.
  def change do
    alter table(:sourcing_orgs) do
      add :promotion, :string
    end

    create constraint(:sourcing_orgs, :promotion_values,
             check: "promotion is null or promotion in ('created', 'linked')"
           )
  end
end
