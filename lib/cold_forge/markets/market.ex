defmodule ColdForge.Markets.Market do
  @moduledoc """
  What the screens call a campaign: one push inside a project, named however
  it's run — a state ("Michigan"), a city ("Grand Rapids") or a segment ("Dog
  breeders, Texas").

  Named `Market` in code because `Campaign` already means an email sequence
  here, and two things with one name is how the wrong one gets edited.

  A campaign owns its searches and its email sequences. Its people are whoever
  those searches added or those sequences enrolled, and its calls, postcards,
  replies and activity are theirs — so nothing else needs a campaign key.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  schema "markets" do
    field :name, :string
    field :notes, :string

    belongs_to :project, ColdForge.Outreach.Project
    has_many :sources, ColdForge.Sourcing.Source
    has_many :campaigns, ColdForge.Outreach.Campaign

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(market, attrs) do
    market
    |> cast(attrs, [:project_id, :name, :notes])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:project_id, :name])
    |> validate_length(:name, max: 80)
    |> foreign_key_constraint(:project_id)
  end
end
