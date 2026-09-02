defmodule ColdForge.Sending.Window do
  @moduledoc """
  Decides *when* a step may go out.

  Cold mail that arrives at 3am on a Sunday announces itself as automation, so
  every send time is pushed forward into the campaign's configured business
  hours and days, in the project's own timezone.
  """

  alias ColdForge.Outreach.{Project, Campaign}

  @doc """
  The next moment at or after `from` that falls inside the campaign's send
  window, as UTC.

  Walks forward a day at a time rather than doing modular arithmetic because
  DST means "8am local tomorrow" isn't a fixed number of hours from "8am local
  today" — only a real local-time construction gets that right.
  """
  def next_open_slot(%Campaign{} = campaign, %Project{} = project, %DateTime{} = from) do
    tz = project.timezone || "Etc/UTC"

    local =
      case DateTime.shift_zone(from, tz) do
        {:ok, shifted} -> shifted
        # An unknown timezone shouldn't stop the drip; UTC is a safe fallback.
        {:error, _} -> from
      end

    advance(local, campaign, 0)
  end

  # 14 days of lookahead is far more than any window can need — a campaign that
  # sends on at least one weekday always resolves within seven. The bound just
  # stops a misconfigured `send_days` from looping forever.
  defp advance(_local, _campaign, 14), do: nil

  defp advance(local, campaign, attempts) do
    cond do
      not day_allowed?(local, campaign) ->
        local |> start_of_next_day(campaign) |> advance(campaign, attempts + 1)

      local.hour < campaign.send_window_start ->
        local |> at_hour(campaign.send_window_start) |> to_utc()

      local.hour >= campaign.send_window_end ->
        local |> start_of_next_day(campaign) |> advance(campaign, attempts + 1)

      true ->
        to_utc(local)
    end
  end

  defp day_allowed?(local, campaign) do
    local |> DateTime.to_date() |> Date.day_of_week() |> Kernel.in(campaign.send_days)
  end

  defp start_of_next_day(local, campaign) do
    local
    |> DateTime.to_date()
    |> Date.add(1)
    |> build_local(campaign.send_window_start, local.time_zone)
  end

  defp at_hour(local, hour), do: build_local(DateTime.to_date(local), hour, local.time_zone)

  # A local wall-clock time can be ambiguous (the hour that repeats when DST
  # ends) or nonexistent (the hour that's skipped when it starts). Neither is
  # worth surfacing to the operator — pick a real instant and move on.
  defp build_local(date, hour, tz) do
    naive = NaiveDateTime.new!(date, Time.new!(hour, 0, 0))

    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> dt
      {:ambiguous, first, _second} -> first
      {:gap, _just_before, just_after} -> just_after
      {:error, _} -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  defp to_utc(local) do
    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end
end
