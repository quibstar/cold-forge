defmodule ColdForge.Repo.Migrations.CreateFlyers do
  use Ecto.Migration

  # Printed counter flyers, one per place they're put up, each with its own QR
  # code. The code is in the URL the QR encodes, so a scan says which counter it
  # came from — which is the whole point: after a month, the next batch goes to
  # the counters that produced scans.
  def change do
    # What the flyer says, per project. A map rather than columns: it's one
    # document, edited and printed as a whole.
    alter table(:projects) do
      add :flyer, :map, default: %{}
    end

    create table(:flyer_placements) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Where it came from, when it was found by a sourcing search. Nilified
      # rather than deleted with the org: a flyer stapled to a board outlives
      # the search that found the board.
      add :org_id, references(:sourcing_orgs, type: :binary_id, on_delete: :nilify_all)

      add :venue_name, :string, null: false
      add :address, :string
      add :phone, :string
      add :code, :string, null: false
      add :trade, :string
      add :status, :string, null: false, default: "planned"
      add :notes, :text
      add :scans_count, :integer, null: false, default: 0
      add :last_scanned_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Global, not per project: the code is the whole of the public URL.
    create unique_index(:flyer_placements, [:code])
    create index(:flyer_placements, [:project_id])
    create index(:flyer_placements, [:org_id])

    create table(:flyer_scans) do
      add :placement_id,
          references(:flyer_placements, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_agent, :string, size: 500

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:flyer_scans, [:placement_id])
  end
end
