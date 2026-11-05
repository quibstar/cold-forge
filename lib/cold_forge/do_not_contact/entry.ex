defmodule ColdForge.DoNotContact.Entry do
  @moduledoc """
  One company on a project's do-not-contact list: its name and, when known,
  its web domain.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  schema "do_not_contacts" do
    field :name, :string
    field :domain, :string
    field :notes, :string

    belongs_to :project, ColdForge.Outreach.Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:name, :domain, :notes])
    |> update_change(:name, &String.trim/1)
    |> update_change(:domain, &ColdForge.DoNotContact.domain/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
  end
end
