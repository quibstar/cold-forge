defmodule ColdForge.Outreach.Message do
  @moduledoc """
  One email we tried to send. The rendered subject/body are stored as they went
  out, so what a prospect saw is recoverable even after the step is edited.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(pending sent failed bounced)

  schema "messages" do
    field :subject, :string
    field :body, :string
    field :status, :string, default: "pending"
    field :sent_at, :utc_datetime
    field :failed_at, :utc_datetime
    field :error, :string
    field :provider_message_id, :string
    field :open_token, :string
    field :first_opened_at, :utc_datetime
    field :open_count, :integer, default: 0

    belongs_to :project, ColdForge.Outreach.Project
    belongs_to :prospect, ColdForge.Outreach.Prospect
    belongs_to :enrollment, ColdForge.Outreach.Enrollment
    belongs_to :campaign_step, ColdForge.Outreach.CampaignStep
    has_many :tracked_links, ColdForge.Tracking.TrackedLink

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :project_id,
      :prospect_id,
      :enrollment_id,
      :campaign_step_id,
      :subject,
      :body,
      :status,
      :sent_at,
      :failed_at,
      :error,
      :provider_message_id
    ])
    |> validate_required([:project_id, :prospect_id, :subject, :body])
    |> validate_inclusion(:status, @statuses)
    |> put_open_token()
    |> unique_constraint(:open_token)
  end

  defp put_open_token(changeset) do
    case get_field(changeset, :open_token) do
      nil -> put_change(changeset, :open_token, ColdForge.Tracking.Token.generate())
      _ -> changeset
    end
  end
end
