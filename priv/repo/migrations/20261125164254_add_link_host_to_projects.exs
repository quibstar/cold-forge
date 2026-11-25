defmodule ColdForge.Repo.Migrations.AddLinkHostToProjects do
  use Ecto.Migration

  # The host a project's emails link to (unsubscribe, click tracking, opens),
  # so a Furizzma email doesn't carry an Affordable Startup address. Nil keeps
  # the app's own host.
  def change do
    alter table(:projects) do
      add :link_host, :string
    end
  end
end
