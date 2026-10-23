defmodule ColdForge.Flyers.Placement do
  @moduledoc """
  One flyer in one place — a supply-house counter, a lumber yard's board.

  The `code` is the whole of the public URL its QR encodes (`/f/:code`), so a
  scan is counted against the place it was standing. After a month that says
  which counters produced anybody, and the next batch goes there instead.

  Never deleted once printed: a flyer stapled to a board outlives any record of
  it, and its QR has to keep working. `removed` is how it stops counting.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(planned asked posted declined removed)

  schema "flyer_placements" do
    field :venue_name, :string
    field :address, :string
    field :phone, :string
    field :code, :string
    # Passed on to the landing page as `?t=`, so it can name the trade the
    # counter serves — and swaps the flyer's eyebrow for the trade one.
    field :trade, :string
    field :status, :string, default: "planned"
    field :notes, :string
    field :scans_count, :integer, default: 0
    field :last_scanned_at, :utc_datetime

    belongs_to :project, ColdForge.Outreach.Project
    belongs_to :org, ColdForge.Sourcing.Org

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:venue_name, :address, :phone, :trade, :status, :notes])
    |> validate_required([:venue_name])
    |> validate_inclusion(:status, @statuses)
    |> update_change(:trade, &(&1 |> String.trim() |> String.downcase()))
    |> unique_constraint(:venue_name,
      name: :flyer_placements_one_per_place_index,
      message: "already has a flyer at that address"
    )
  end

  @doc false
  def create_changeset(placement, attrs) do
    placement
    |> changeset(attrs)
    |> cast(attrs, [:code])
    |> validate_required([:code])
    # Lowercase, digits and dashes: it's typed off the flyer as often as it's
    # scanned, and it's a URL segment.
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9-]{0,59}$/,
      message: "lowercase letters, numbers and dashes, 60 at most"
    )
    |> unique_constraint(:code, message: "is already on another flyer")
  end
end
