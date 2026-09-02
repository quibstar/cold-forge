defmodule ColdForge.Outreach.CampaignStep do
  @moduledoc """
  One email in a campaign. `delay_days` is measured from the *previous* step,
  which is what you actually think in when writing a drip ("then wait 3 days").
  """
  use ColdForge.Schema
  import Ecto.Changeset

  schema "campaign_steps" do
    field :position, :integer
    field :delay_days, :integer, default: 0
    field :subject, :string
    field :body, :string

    belongs_to :campaign, ColdForge.Outreach.Campaign
    # Which survey `{{survey}}` renders in this email, if any.
    belongs_to :survey, ColdForge.Survey.Survey

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:campaign_id, :position, :delay_days, :subject, :body, :survey_id])
    |> validate_required([:campaign_id, :position, :subject, :body])
    |> validate_number(:delay_days, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:campaign_id, :position])
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:survey_id)
  end
end
