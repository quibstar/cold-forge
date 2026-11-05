defmodule ColdForge.Repo.Migrations.CreatePostcards do
  use Ecto.Migration

  # A postcard mailed to one prospect, with its own QR code. The address is
  # copied onto the card when it's added, so what was printed stays on record
  # even if the prospect's details change later.
  def change do
    create table(:postcards) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :prospect_id, references(:prospects, type: :binary_id, on_delete: :nilify_all)
      add :code, :string, null: false
      add :name, :string, null: false
      add :street, :string, null: false
      add :city, :string, null: false
      add :region, :string, null: false
      add :postal_code, :string, null: false
      add :trade, :string
      add :status, :string, null: false, default: "planned"
      add :mailed_at, :utc_datetime
      add :scans_count, :integer, null: false, default: 0
      add :last_scanned_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:postcards, [:code])
    create unique_index(:postcards, [:project_id, :prospect_id])
    create index(:postcards, [:project_id])

    create table(:postcard_scans) do
      add :postcard_id, references(:postcards, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_agent, :string, size: 500

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:postcard_scans, [:postcard_id])
  end
end
