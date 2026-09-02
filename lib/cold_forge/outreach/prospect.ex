defmodule ColdForge.Outreach.Prospect do
  @moduledoc """
  Someone we might email. Status tracks the terminal outcomes that should stop
  outreach — replied, bounced, unsubscribed — so the scheduler can skip them
  without consulting every campaign they're in.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(new active replied bounced unsubscribed completed)

  schema "prospects" do
    field :email, :string
    field :first_name, :string
    field :last_name, :string
    field :company, :string
    field :title, :string
    field :industry, :string
    field :phone, :string
    field :website, :string
    field :custom_fields, :map, default: %{}
    # Form-only: the one-per-line text the operator edits, parsed into
    # `custom_fields` before cast. Kept virtual so a half-typed line survives a
    # validate round trip instead of snapping back to the saved map.
    field :custom_fields_text, :string, virtual: true
    field :source, :string
    field :notes, :string
    field :status, :string, default: "new"
    field :unsubscribed_at, :utc_datetime
    field :bounced_at, :utc_datetime
    field :replied_at, :utc_datetime
    field :unsubscribe_token, :string

    belongs_to :project, ColdForge.Outreach.Project
    has_many :enrollments, ColdForge.Outreach.Enrollment

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(prospect, attrs) do
    prospect
    |> cast(ColdForge.MergeFields.parse(attrs, "custom_fields"), [
      :project_id,
      :email,
      :first_name,
      :last_name,
      :company,
      :title,
      :industry,
      :phone,
      :website,
      :custom_fields,
      :custom_fields_text,
      :source,
      :notes,
      :status
    ])
    |> validate_required([:project_id, :email])
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email"
    )
    |> validate_inclusion(:status, @statuses)
    |> put_unsubscribe_token()
    |> unique_constraint([:project_id, :email],
      message: "is already a prospect on this project"
    )
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Every merge tag this prospect resolves, and what it resolves to.

  The point is answering "why did the email say *that*" without reading the
  renderer: a blank here is a tag that will fall back, and a fallback nobody
  wrote is an empty gap in somebody's inbox.
  """
  def merge_values(%__MODULE__{} = prospect) do
    built_in = [
      {"first_name", prospect.first_name},
      {"last_name", prospect.last_name},
      {"full_name", display_name(prospect)},
      {"email", prospect.email},
      {"company", prospect.company},
      {"title", prospect.title},
      {"industry", prospect.industry},
      {"phone", prospect.phone},
      {"website", prospect.website}
    ]

    custom =
      prospect.custom_fields
      |> Kernel.||(%{})
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()

    built_in ++ custom
  end

  defp put_unsubscribe_token(changeset) do
    case get_field(changeset, :unsubscribe_token) do
      nil -> put_change(changeset, :unsubscribe_token, ColdForge.Tracking.Token.generate())
      _ -> changeset
    end
  end

  @doc "Display name, falling back to the email when we only have an address."
  def display_name(%__MODULE__{} = prospect) do
    case String.trim("#{prospect.first_name} #{prospect.last_name}") do
      "" -> prospect.email
      name -> name
    end
  end

  @doc """
  Whether this prospect may still be emailed. Suppression is checked separately
  by `ColdForge.Outreach.suppressed?/1` — that list is global.
  """
  def mailable?(%__MODULE__{status: status}), do: status in ["new", "active"]
end
