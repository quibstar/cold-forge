defmodule ColdForge.Tracking.LinkClick do
  @moduledoc "One click on a tracked link. Kept per-event so repeat visits show."
  use Ecto.Schema
  import Ecto.Changeset

  schema "link_clicks" do
    field :ip, :string
    field :user_agent, :string
    field :clicked_at, :utc_datetime

    belongs_to :tracked_link, ColdForge.Tracking.TrackedLink

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(click, attrs) do
    click
    |> cast(attrs, [:tracked_link_id, :ip, :user_agent, :clicked_at])
    |> validate_required([:tracked_link_id, :clicked_at])
    |> foreign_key_constraint(:tracked_link_id)
  end
end
