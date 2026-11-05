defmodule ColdForge.Postcards.Postcard do
  @moduledoc """
  One postcard mailed to one prospect.

  The `code` is the whole of the public URL its QR encodes (`/m/:code`), so a
  scan says exactly who it came from — which is what a flyer on a counter can't
  do. The address is copied on when the card is added: what went in the mail
  stays on record even if the prospect is edited later.

  Never deleted once mailed: the card is on somebody's desk, and its QR has to
  keep working.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(planned mailed returned)

  schema "postcards" do
    field :code, :string
    field :name, :string
    field :street, :string
    field :city, :string
    field :region, :string
    field :postal_code, :string
    field :trade, :string
    field :status, :string, default: "planned"
    field :mailed_at, :utc_datetime
    field :scans_count, :integer, default: 0
    field :last_scanned_at, :utc_datetime

    belongs_to :project, ColdForge.Outreach.Project
    belongs_to :prospect, ColdForge.Outreach.Prospect

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(postcard, attrs) do
    postcard
    |> cast(attrs, [:code, :name, :street, :city, :region, :postal_code, :trade, :status])
    |> validate_required([:code, :name, :street, :city, :region, :postal_code])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:code)
    |> unique_constraint(:prospect_id,
      name: :postcards_project_id_prospect_id_index,
      message: "already has a postcard"
    )
  end

  @doc "The last line of the address block: `Grandville, MI 49418`."
  def city_line(%__MODULE__{} = card), do: "#{card.city}, #{card.region} #{card.postal_code}"
end
