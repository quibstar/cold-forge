defmodule ColdForge.Repo.Migrations.CreateSourcingOrgs do
  use Ecto.Migration

  # An organisation we found ourselves, before it is worth making a prospect of.
  #
  # Separate from `prospects` on purpose. Discovery turns up far more rows than
  # are worth emailing: no website, no address published, a notice asking not
  # to be solicited, or simply the wrong kind of business. Promoting straight
  # into `prospects` would mean the send list carries all of that, and the
  # evidence for each row would be gone by the time anyone asked.
  #
  # So this is the staging area. A row here records where it came from and what
  # we found; only the ones that survive become a prospect, and the rest stay
  # as the reason we didn't write to them.
  def change do
    create table(:sourcing_orgs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :name, :string, null: false
      # roofing | siding | windows | gutters | shelter | rescue | humane_society
      # | breeder — what we think they are, from the source that listed them.
      add :segment, :string, null: false

      add :website, :string
      add :phone, :string
      add :street, :string
      add :city, :string
      add :region, :string
      add :postal_code, :string
      add :country, :string, null: false, default: "US"

      # Which discovery source listed them, and its own stable id for the row
      # (an OSM node id, an EIN, a licence number). Together these are unique,
      # so re-running a source updates rather than duplicates.
      add :source, :string, null: false
      add :source_ref, :string, null: false
      # The page or file the row came from, for the same reason every address
      # carries one: a list you cannot trace is a list you cannot defend.
      add :source_url, :string
      add :raw, :map, null: false, default: %{}

      # discovered -> needs_website -> fetched -> promoted | rejected
      add :status, :string, null: false, default: "discovered"
      add :reject_reason, :string

      # Filled in by the crawl. `no_solicitation` is the one that overrides
      # everything else: a published address on a page that asks not to be
      # solicited is not a lead.
      add :email, :string
      add :email_source_url, :string
      add :email_presentation, :string
      add :no_solicitation, :boolean, null: false, default: false
      add :notice_text, :text
      add :has_contact_form, :boolean, null: false, default: false
      add :fetched_at, :utc_datetime

      add :prospect_id, references(:prospects, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sourcing_orgs, [:source, :source_ref])
    create index(:sourcing_orgs, [:status])
    create index(:sourcing_orgs, [:segment])
    create index(:sourcing_orgs, [:prospect_id])
    # The crawl queue: everything with a website we haven't fetched yet.
    create index(:sourcing_orgs, [:status, :segment], where: "website IS NOT NULL")
  end
end
