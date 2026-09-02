defmodule ColdForge.Repo.Migrations.AddBrandingAndBlasts do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # Appended above the compliance footer. This is the branding that belongs
      # in cold mail — a person's sign-off, not a letterhead.
      add :signature, :text
      # Used only by branded blasts, never by drips.
      add :logo_url, :string
      add :brand_color, :string
    end

    alter table(:sequences) do
      # "drip" is the multi-step default. "blast" is a single email to a list —
      # same machinery (caps, send window, unsubscribe, tracking), different
      # authoring flow.
      add :kind, :string, null: false, default: "drip"
      # Wraps the body in a branded HTML shell. Off for drips on purpose: a
      # designed template is the clearest "this is bulk mail" signal there is.
      add :branded, :boolean, null: false, default: false
    end

    create index(:sequences, [:project_id, :kind])
  end
end
