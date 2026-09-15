defmodule ColdForge.Repo.Migrations.OptionalProspectEmail do
  use Ecto.Migration

  # A prospect is someone we can reach, and a phone number is enough for that.
  # Lists built for calling — owner-operated trades, most of whom publish a
  # phone and no address — would otherwise lose most of their rows on import.
  #
  # The check keeps the one guarantee that still matters: no prospect with no
  # way to reach them at all. The unique index on (project_id, email) needs no
  # change — Postgres treats NULLs as distinct, so any number of phone-only
  # prospects can share a project.
  def change do
    alter table(:prospects) do
      modify :email, :citext, null: true, from: {:citext, null: false}
    end

    create constraint(:prospects, :email_or_phone,
             check: "email IS NOT NULL OR (phone IS NOT NULL AND phone <> '')"
           )
  end
end
