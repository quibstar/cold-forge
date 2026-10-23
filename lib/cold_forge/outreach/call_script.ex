defmodule ColdForge.Outreach.CallScript do
  @moduledoc """
  One script: a template with merge tags, belonging to a project, read as a
  tab on the call page in `position` order.

  Voicemails were a second kind for a while, listed under every tab. They are
  words to read like any other, so they are a script now — one called
  "Voicemails" — and `script` is the only kind left. The column stays so the
  table needn't change shape for it.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @kinds ~w(script)

  schema "call_scripts" do
    field :kind, :string, default: "script"
    field :name, :string
    field :body, :string
    field :position, :integer

    belongs_to :project, ColdForge.Outreach.Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(script, attrs) do
    script
    |> cast(attrs, [:project_id, :kind, :name, :body, :position])
    |> update_change(:name, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:project_id, :kind, :name, :body])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 80)
    |> validate_number(:position, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    # Named and pointed at `position` on purpose: the default would hang the
    # error on `project_id`, which is a hidden field, so the form would refuse
    # to save and show nothing at all.
    |> unique_constraint(:position,
      name: :call_scripts_project_id_kind_position_index,
      message: "is already taken by another one — two can't share a number"
    )
  end

  @doc """
  Whether the body leaves a merge tag with no fallback.

  `{{industry}}` renders as nothing when the field is empty, which in a script
  being read out loud is a hole in the middle of a sentence. `{{industry|exterior}}`
  says a word instead. Reported rather than rejected: a tag that is always set
  is fine without one, and the person writing it knows their own data.
  """
  def tags_without_fallback(%__MODULE__{body: body}) when is_binary(body) do
    ~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  def tags_without_fallback(_), do: []
end
