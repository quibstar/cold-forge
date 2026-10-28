defmodule ColdForge.Repo.Migrations.AddForwardRepliesToProjects do
  use Ecto.Migration

  # Where a reply goes once the app has read it. Replies now come back to the
  # sending domain so the drip can stop itself; this keeps a copy landing in a
  # person's real inbox, where they can answer it.
  def change do
    alter table(:projects) do
      add :forward_replies_to, :string
    end
  end
end
