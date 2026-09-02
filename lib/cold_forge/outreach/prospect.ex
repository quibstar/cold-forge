defmodule ColdForge.Outreach.Prospect do
  @moduledoc """
  Someone we might email. Status tracks the terminal outcomes that should stop
  outreach — replied, bounced, unsubscribed — so the scheduler can skip them
  without consulting every campaign they're in.
  """
  use Ecto.Schema
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
    |> cast(attrs, [
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
