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
    # `:delete` because the form is the source of truth for which questions
    # exist: removing a row means the question is gone, along with its answers.
    has_many :questions, ColdForge.Survey.Question,
      preload_order: [asc: :position],
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the survey and its questions together, so the whole thing is edited on
  one screen rather than a page per question.

  `sort_param` and `drop_param` are what make the rows dynamic: the form posts
  an ordering array and a deletion array, and Ecto reorders and removes
  accordingly.

  Each row also posts its own `position`, taken from its index in the rendered
  form. Renumbering here instead — via `update_change(:questions, ...)` — looks
  tempting and does not work: re-putting the relation's list re-runs Ecto's
  relation checks, and a child already marked `:replace` by `drop_param` makes
  that raise.
  """
  def changeset(survey, attrs) do
    survey
    |> cast(attrs, [:project_id, :name, :intro, :thank_you])
    |> validate_required([:project_id, :name])
    |> cast_assoc(:questions, sort_param: :questions_order, drop_param: :questions_delete)
    |> foreign_key_constraint(:project_id)
  end
end
