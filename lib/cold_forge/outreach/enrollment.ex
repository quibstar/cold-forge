defmodule ColdForge.Outreach.Enrollment do
  @moduledoc """
  A prospect's progress through one campaign. `next_send_at` is the scheduler's
  only input — everything else about pacing is decided when it's written.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused completed stopped)

  schema "enrollments" do
    field :status, :string, default: "active"
    field :current_position, :integer, default: 0
    field :next_send_at, :utc_datetime
    field :stopped_reason, :string
    field :completed_at, :utc_datetime
    field :answered_at, :utc_datetime

    belongs_to :campaign, ColdForge.Outreach.Campaign
    belongs_to :prospect, ColdForge.Outreach.Prospect
    has_many :messages, ColdForge.Outreach.Message

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(enrollment, attrs) do
    enrollment
    |> cast(attrs, [
      :campaign_id,
      :prospect_id,
      :status,
      :current_position,
      :next_send_at,
      :stopped_reason,
      :completed_at,
      :answered_at
    ])
    |> validate_required([:campaign_id, :prospect_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:campaign_id, :prospect_id],
      message: "is already enrolled in this campaign"
    )
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:prospect_id)
  end
end
