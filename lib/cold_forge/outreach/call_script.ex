defmodule ColdForge.Outreach.CallScript do
  @moduledoc """
  One script or voicemail: a template with merge tags, belonging to a project.

  Both kinds are the same thing — words written once, read with one prospect's
  details in them — so they share a table and differ only in where they are
  read. A `script` is a tab on the call page. A `voicemail` is one step of the
  cadence, and its `position` is the number a call records when it is left.

  They used to be fixed keys in two maps on the project: three scripts, four
  voicemails, no way to add a fifth or drop one. That was never a decision
  about how many a person should be allowed, just the shape the data arrived
  in.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @kinds ~w(script voicemail)

  schema "call_scripts" do
    field :kind, :string, default: "script"
    field :name, :string
    field :body, :string
    field :position, :integer

    belongs_to :project, ColdForge.Outreach.Project

    timestamps(type: :utc_datetime)
  end

  @doc "The two lists a script can belong to."
  def kinds, do: @kinds

  @doc "How each reads on screen."
  def kind_label("script"), do: "Script"
  def kind_label("voicemail"), do: "Voicemail"
  def kind_label(other), do: other

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
