defmodule ColdForge.Repo.Migrations.AddLogoUploadToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      # Path under priv/static for a logo uploaded through the admin, as
      # distinct from `logo_url`, which points at one hosted somewhere else.
      # Kept separate so removing an upload can't silently blank out a URL the
      # operator typed, and vice versa.
      add :logo_path, :string
    end
  end
end
