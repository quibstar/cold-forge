defmodule ColdForge.Survey.Survey do
  @moduledoc """
  A named set of questions belonging to a project, reusable across campaigns.

  Reusable is the point. Asking the same question in three campaigns and
  comparing the answers is what makes this research rather than a poll — if a
  survey belonged to one campaign, every campaign would produce its own
  unrelated result set.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "surveys" do
    field :name, :string
    field :intro, :string
    field :thank_you, :string

    belongs_to :project, ColdForge.Outreach.Project
    has_many :questions, ColdForge.Survey.Question, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(survey, attrs) do
    survey
    |> cast(attrs, [:project_id, :name, :intro, :thank_you])
    |> validate_required([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end
end
