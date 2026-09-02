defmodule ColdForge.Outreach.SequenceStep do
  @moduledoc """
  One email in a sequence. `delay_days` is measured from the *previous* step,
  which is what you actually think in when writing a drip ("then wait 3 days").
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sequence_steps" do
    field :position, :integer
    field :delay_days, :integer, default: 0
    field :subject, :string
    field :body, :string

    belongs_to :sequence, ColdForge.Outreach.Sequence

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:sequence_id, :position, :delay_days, :subject, :body])
    |> validate_required([:sequence_id, :position, :subject, :body])
    |> validate_number(:delay_days, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:sequence_id, :position])
    |> foreign_key_constraint(:sequence_id)
  end
end
