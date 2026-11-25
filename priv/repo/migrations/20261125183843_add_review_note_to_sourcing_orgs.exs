defmodule ColdForge.Repo.Migrations.AddReviewNoteToSourcingOrgs do
  use Ecto.Migration

  # Why a found place is held back for a person to look at before it can be
  # added to a drip: a breeder search result whose website reads like a
  # groomer, boarder or trainer. Nil means nothing to check.
  def change do
    alter table(:sourcing_orgs) do
      add :review_note, :string
    end
  end
end
