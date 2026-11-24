defmodule ColdForge.Repo.Migrations.AddFromEmailToCampaigns do
  use Ecto.Migration

  # A drip's own sending address, so a project can move to a new one drip by
  # drip while it warms up. Null sends from the project's address.
  def change do
    alter table(:campaigns) do
      add :from_email, :citext
    end
  end
end
