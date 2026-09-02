defmodule ColdForge.Outreach.Suppression do
  @moduledoc """
  The do-not-contact list. Deliberately global rather than per-project: someone
  who unsubscribes from one idea should not hear from the next one.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @reasons ~w(unsubscribed bounced complained manual)

  schema "suppressions" do
    field :email, :string
    field :reason, :string
    field :notes, :string

    belongs_to :project, ColdForge.Outreach.Project

    timestamps(type: :utc_datetime)
  end

  def reasons, do: @reasons

  @doc false
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [:email, :reason, :notes, :project_id])
    |> validate_required([:email, :reason])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint(:email)
  end
end
