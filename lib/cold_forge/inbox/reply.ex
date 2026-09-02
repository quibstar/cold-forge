defmodule ColdForge.Inbox.Reply do
  @moduledoc """
  A reply that came back from a prospect.

  Stored rather than merely acted on: the whole point of cold outreach is the
  conversations it starts, and "12 sent, 1 replied" is worth nothing without
  being able to read the one.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @matched_by ~w(exact address)

  schema "replies" do
    field :from_email, :string
    field :subject, :string
    field :body, :string
    field :matched_by, :string
    field :automated, :boolean, default: false
    field :received_at, :utc_datetime
    field :external_id, :string

    belongs_to :prospect, ColdForge.Outreach.Prospect
    belongs_to :message, ColdForge.Outreach.Message

    timestamps(type: :utc_datetime)
  end

  def matched_by_values, do: @matched_by

  @doc false
  def changeset(reply, attrs) do
    reply
    |> cast(attrs, [
      :prospect_id,
      :message_id,
      :from_email,
      :subject,
      :body,
      :matched_by,
      :automated,
      :received_at,
      :external_id
    ])
    |> validate_required([:prospect_id, :from_email, :matched_by, :received_at])
    |> validate_inclusion(:matched_by, @matched_by)
    |> update_change(:from_email, &(&1 |> String.trim() |> String.downcase()))
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:prospect_id)
  end
end
