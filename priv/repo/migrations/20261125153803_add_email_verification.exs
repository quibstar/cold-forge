defmodule ColdForge.Repo.Migrations.AddEmailVerification do
  use Ecto.Migration

  # What Reoon said about an address, and when. Kept on both the place the
  # contact finder found and the prospect made from it, so "why wasn't this one
  # added" and "was this address checked" are answerable from either side.
  def change do
    alter table(:sourcing_orgs) do
      add :email_verdict, :string
      add :email_checked_at, :utc_datetime
    end

    alter table(:prospects) do
      add :email_verdict, :string
      add :email_checked_at, :utc_datetime
    end
  end
end
