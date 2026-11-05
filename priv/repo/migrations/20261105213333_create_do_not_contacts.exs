defmodule ColdForge.Repo.Migrations.CreateDoNotContacts do
  use Ecto.Migration

  # Companies a project must never reach by any channel — email, call or
  # postcard — by name and, when known, by web domain. The email suppression
  # list can't do this: it's one address at a time, and a company found again
  # by a new search arrives with a new prospect and often no address at all.
  def change do
    create table(:do_not_contacts) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :domain, :string
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:do_not_contacts, [:project_id])
  end
end
