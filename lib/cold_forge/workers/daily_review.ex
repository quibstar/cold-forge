defmodule ColdForge.Workers.DailyReview do
  @moduledoc """
  Weekday mornings: slows any drip whose bounces spiked, then queues the
  morning email (`ColdForge.Workers.DailyReportEmail`) with what it changed.

  Slowing is the one change this makes on its own. Pausing, activating, editing
  copy and picking an opener-test winner stay with a person; the report only
  recommends them.

  One attempt only, and unique for most of a day: a retry after slowing would
  halve the same drip twice. The email is its own job so a mail hiccup can
  retry without touching campaigns.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 1, unique: [period: 60 * 60 * 20]

  alias ColdForge.{Outreach, Reports}
  alias ColdForge.Workers.DailyReportEmail

  @impl Oban.Worker
  def perform(_job) do
    report = Reports.daily()

    actions =
      for row <- report.slow do
        campaign = Outreach.get_campaign!(row.campaign.id)

        case Reports.slow_campaign(campaign, Reports.slow_reason(row)) do
          {:ok, sentence} -> sentence
          {:error, _} -> "Tried to slow #{campaign.name} but the change didn't save. Check it by hand."
        end
      end

    %{"actions" => actions} |> DailyReportEmail.new() |> Oban.insert()
    :ok
  end
end
