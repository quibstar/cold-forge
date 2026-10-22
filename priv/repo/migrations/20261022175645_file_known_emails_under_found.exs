defmodule ColdForge.Repo.Migrations.FileKnownEmailsUnderFound do
  use Ecto.Migration

  # A second look at a website that found nothing used to reject the place as
  # "no address published" — keeping the email the first look had found. Those
  # places have an address; they belong with the others that do. The crawler no
  # longer does this, so this only tidies what it already did.
  def up do
    execute """
    UPDATE sourcing_orgs
       SET status = 'fetched', reject_reason = NULL
     WHERE status = 'rejected'
       AND reject_reason = 'no_address_published'
       AND email IS NOT NULL
       AND email <> ''
    """
  end

  # Nothing to restore: the rows it moved were filed wrongly.
  def down, do: :ok
end
