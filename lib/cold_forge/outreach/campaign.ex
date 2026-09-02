defmodule ColdForge.Outreach.Campaign do
  @moduledoc """
  A campaign: an ordered set of emails plus the window they're allowed to go
  out in.

  One email with no delay is a blast; several with delays is a drip. That's the
  only difference between them, so there's no `kind` — the steps already say
  which it is.

  The window and daily cap live here rather than on the project because two
  campaigns on the same project may want very different pacing.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @statuses ~w(draft active paused archived)

  schema "campaigns" do
    field :name, :string
    field :status, :string, default: "draft"
    field :branded, :boolean, default: false
    field :stop_on_answer, :boolean, default: true
    field :send_window_start, :integer, default: 8
    field :send_window_end, :integer, default: 17
    field :send_days, {:array, :integer}, default: [1, 2, 3, 4, 5]
    field :daily_cap, :integer, default: 50

    belongs_to :project, ColdForge.Outreach.Project
    has_many :steps, ColdForge.Outreach.CampaignStep, preload_order: [asc: :position]
    has_many :enrollments, ColdForge.Outreach.Enrollment

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [
      :project_id,
      :name,
      :status,
      :branded,
      :stop_on_answer,
      :send_window_start,
      :send_window_end,
      :send_days,
      :daily_cap
    ])
    |> validate_required([:project_id, :name])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:send_window_start, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:send_window_end, greater_than_or_equal_to: 1, less_than_or_equal_to: 24)
    |> validate_number(:daily_cap, greater_than: 0)
    |> validate_window()
    |> validate_send_days()
    |> foreign_key_constraint(:project_id)
  end

  defp validate_window(changeset) do
    start = get_field(changeset, :send_window_start)
    finish = get_field(changeset, :send_window_end)

    if is_integer(start) and is_integer(finish) and finish <= start do
      add_error(changeset, :send_window_end, "must be after the window start")
    else
      changeset
    end
  end

  defp validate_send_days(changeset) do
    validate_change(changeset, :send_days, fn :send_days, days ->
      cond do
        days == [] -> [send_days: "pick at least one day"]
        Enum.all?(days, &(&1 in 1..7)) -> []
        true -> [send_days: "must be ISO day numbers (1 = Monday)"]
      end
    end)
  end
end
