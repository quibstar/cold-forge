defmodule ColdForge.Workers.DailyReportEmail do
  @moduledoc """
  The morning email: the one-line status as the subject, interested replies
  first, then warnings, any drip that was slowed, and a link to the full page.

  Goes to each active project's `forward_replies_to`, the inbox replies already
  go to, once per address.
  """
  use Oban.Worker, queue: :sending, max_attempts: 3

  import Ecto.Query

  alias ColdForge.{Mailer, Reports, Repo}
  alias ColdForge.Outreach.Project

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    actions = Map.get(args, "actions", [])
    report = Reports.daily()

    Repo.all(from p in Project, where: p.active, order_by: p.name)
    |> Enum.filter(&(is_binary(&1.forward_replies_to) and &1.forward_replies_to != ""))
    |> Enum.uniq_by(&String.downcase(&1.forward_replies_to))
    |> Enum.reduce_while(:ok, fn project, :ok ->
      Swoosh.Email.new()
      |> Swoosh.Email.to(project.forward_replies_to)
      |> Swoosh.Email.from({"Cold Forge", project.from_email})
      |> Swoosh.Email.subject(subject(report, actions))
      |> Swoosh.Email.text_body(body(report, actions))
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  def subject(report, actions) do
    status = if actions != [] and report.hot == [], do: "#{report.status}, #{length(actions)} drip(s) slowed", else: report.status
    "Cold email #{Reports.window_label(report.window)}: #{status}"
  end

  @doc false
  def body(report, actions) do
    sections = [
      hot(report),
      warnings(report),
      actions != [] && "Changed automatically:\n" <> Enum.map_join(actions, "\n", &"  - #{&1}"),
      projects(report),
      tests(report),
      "Full report: #{ColdForgeWeb.Endpoint.url()}/admin/report"
    ]

    sections |> Enum.reject(&(&1 in [nil, false, ""])) |> Enum.join("\n\n")
  end

  defp hot(%{hot: []}), do: nil

  defp hot(%{hot: hot}) do
    "Interested replies, answer these first (or send the 6-minute video):\n" <>
      Enum.map_join(hot, "\n", &"  - #{&1.company || &1.email}: \"#{&1.first_line}\"")
  end

  defp warnings(report) do
    lines = for a <- report.addresses, w <- a.warnings, do: "  - #{a.address}: #{w}"
    if lines != [], do: "Sending address warnings:\n" <> Enum.join(lines, "\n")
  end

  defp projects(report) do
    report.projects
    |> Enum.reject(&(&1.rows == []))
    |> Enum.map_join("\n\n", fn %{project: p, rows: rows} ->
      total = fn key -> rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

      "#{p.name}: #{total.(:sent)} sent, #{total.(:bounced)} bounced, #{total.(:complained)} complaints, " <>
        "#{total.(:unsubscribed)} unsubscribed, #{total.(:replies)} replies, #{total.(:waiting)} waiting for email 1"
    end)
  end

  defp tests(%{tests: []}), do: nil

  defp tests(%{tests: tests}) do
    Enum.map_join(tests, "\n\n", fn t ->
      lines =
        Enum.map_join(t.variants, "\n", fn v ->
          "  #{v.letter} (#{v.label}): #{v.sends} sent, #{v.positive} positive, #{v.negative} negative, #{v.unsubscribed} unsubscribed"
        end)

      "#{t.project.name} opener test:\n#{lines}\n  #{t.verdict}"
    end)
  end
end
