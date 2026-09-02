defmodule ColdForge.Repo.Migrations.DropSequenceKind do
  use Ecto.Migration

  # A "blast" was only ever a campaign with one email in it, and modelling that
  # as a separate kind meant two screens, two nav items and a choice to make
  # before you could write anything. The number of emails already tells you
  # which it is.
  def up do
    drop index(:sequences, [:project_id, :kind])

    alter table(:sequences) do
      remove :kind
    end
  end

  def down do
    alter table(:sequences) do
      add :kind, :string, null: false, default: "drip"
    end

    create index(:sequences, [:project_id, :kind])
  end
end
