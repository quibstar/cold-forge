defmodule ColdForge.Tracking.TrackedLink do
  @moduledoc """
  A redirect row: the token that goes in the email, and where it sends someone.

  One row per (message, destination) so a click is attributable to a specific
  send rather than just "someone clicked the demo link".
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracked_links" do
    field :token, :string
    field :destination_url, :string
    field :label, :string
    field :click_count, :integer, default: 0
    field :first_clicked_at, :utc_datetime

    belongs_to :message, ColdForge.Outreach.Message
    has_many :clicks, ColdForge.Tracking.LinkClick

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:message_id, :destination_url, :label])
    |> validate_required([:message_id, :destination_url])
    |> put_token()
    |> unique_constraint(:token)
    |> foreign_key_constraint(:message_id)
  end

  defp put_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, ColdForge.Tracking.Token.generate())
      _ -> changeset
    end
  end
end
