defmodule ColdForge.Repo.Migrations.CreateReplies do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # The RFC 5322 Message-ID we set on the outgoing mail. Ours rather than
      # the provider's, because a reply quotes it in In-Reply-To and that is
      # the only exact way to tie a reply to a specific send. `provider_message_id`
      # is SES's own handle and never appears in a reply.
      add :rfc_message_id, :string
    end

    create unique_index(:messages, [:rfc_message_id])

    create table(:replies) do
      add :prospect_id, references(:prospects, on_delete: :delete_all), null: false
      # Which send it answers, when we can tell. Null for a reply matched only
      # by address — still a reply, just not attributable to one email.
      add :message_id, references(:messages, on_delete: :nilify_all)
      add :from_email, :citext, null: false
      add :subject, :string
      add :body, :text
      # exact | address — how it was matched, so a run of address-matched
      # replies is visible as the weaker signal it is.
      add :matched_by, :string, null: false
      # Set when the reply looks like an out-of-office or a bounce notice rather
      # than a person: those must not stop a campaign.
      add :automated, :boolean, null: false, default: false
      add :received_at, :utc_datetime, null: false
      # The provider's id for the inbound message, so redelivery is a no-op.
      add :external_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:replies, [:prospect_id])
    create index(:replies, [:message_id])
    # Inbound webhooks retry; the same reply must not stop a campaign twice or
    # appear twice in the inbox view.
    create unique_index(:replies, [:external_id])
  end
end
