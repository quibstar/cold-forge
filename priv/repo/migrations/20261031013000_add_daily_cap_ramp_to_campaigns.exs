defmodule ColdForge.Repo.Migrations.AddDailyCapRampToCampaigns do
  use Ecto.Migration

  # Warm-up without anyone remembering to raise the cap: the daily cap is where
  # a campaign starts, `ramp_per_day` is how much it grows for each day it has
  # already sent, and `max_daily_cap` is where it stops.
  def change do
    alter table(:campaigns) do
      add :ramp_per_day, :integer, null: false, default: 0
      add :max_daily_cap, :integer
    end
  end
end
