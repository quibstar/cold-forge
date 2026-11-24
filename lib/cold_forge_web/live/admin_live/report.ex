defmodule ColdForgeWeb.AdminLive.Report do
  @moduledoc """
  The daily review on a page: interested replies first, then sending-address
  health, each project's drips for the last sending day, and any opener test.
  The same numbers the morning email sends; see `ColdForge.Reports`.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Reports

  @impl true
  def mount(_params, _session, socket) do
    report = Reports.daily()

    {:ok,
     socket
     |> assign(:page_title, "Daily report")
     |> assign(:page_subtitle, Reports.window_label(report.window) <> ": " <> report.status)
     |> assign(:report, report)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :if={@report.hot != []} id="hot-replies" class="card bg-success/10 border border-success/30">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-fire" class="size-5" /> Interested replies, answer these first
          </h2>
          <p class="text-sm text-base-content/70">
            Reply yourself or send the 6-minute video. Spotted by keywords, so check the text.
          </p>
          <ul class="mt-2 space-y-1 text-sm">
            <li :for={r <- @report.hot}>
              <span class="font-medium">{r.company || r.email}</span>
              <span :if={r.campaign} class="text-base-content/50">({r.campaign})</span>: “{r.first_line}”
            </li>
          </ul>
        </div>
      </div>

      <div :if={@report.slow != []} id="slow" class="card bg-warning/10 border border-warning/30">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-arrow-trending-down" class="size-5" /> Drips over the bounce limit
          </h2>
          <p class="text-sm text-base-content/70">
            At least 20 sends with over 5% bounced, or a spam complaint. The 8am run halves their daily limits.
          </p>
          <ul class="mt-2 space-y-1 text-sm">
            <li :for={row <- @report.slow}>
              <span class="font-medium">{row.campaign.name}</span>: {Reports.slow_reason(row)}.
              Now {row.campaign.daily_cap} a day, ramping to {row.campaign.max_daily_cap || "no ceiling"}.
            </li>
          </ul>
        </div>
      </div>

      <section id="addresses">
        <h2 class="font-semibold mb-2">Sending addresses</h2>
        <div class="grid gap-4 md:grid-cols-2">
          <div :for={a <- @report.addresses} class="card bg-base-100 shadow-sm">
            <div class="card-body">
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="font-semibold truncate">{a.address}</div>
                  <div class="text-xs text-base-content/50 truncate">{Enum.join(a.projects, ", ")}</div>
                </div>
                <span :if={a.warnings == []} class="badge badge-success badge-sm shrink-0">Healthy</span>
                <span :if={a.warnings != []} class="badge badge-warning badge-sm shrink-0">Check</span>
              </div>

              <div class="grid grid-cols-4 gap-2 mt-3 text-center">
                <.stat label="Sent" value={a.sent} />
                <.stat label="Bounced" value={a.bounced} />
                <.stat label="Complaints" value={a.complaints} />
                <.stat label="7-day bounce" value={Reports.pct(a.week_rate)} />
              </div>

              <div :if={a.days != []} class="mt-3 flex items-end gap-1 h-12" aria-label="Sends per day">
                <div
                  :for={{d, n} <- a.days}
                  class="flex-1 bg-primary/40 rounded-t"
                  style={"height: #{bar(n, a.days)}%"}
                  title={"#{Calendar.strftime(d, "%a %b %-d")}: #{n}"}
                >
                </div>
              </div>

              <ul :if={a.warnings != []} class="mt-3 text-sm text-warning-content space-y-1">
                <li :for={w <- a.warnings} class="flex gap-2">
                  <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 mt-0.5 text-warning" /> {w}
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      <section :for={%{project: p, rows: rows} <- @report.projects} :if={rows != []} id={"project-#{p.id}"}>
        <h2 class="font-semibold mb-2">{p.name}</h2>
        <div class="card bg-base-100 shadow-sm overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Campaign</th>
                <th class="text-right">Sent</th>
                <th class="text-right">Failed</th>
                <th class="text-right">Bounced</th>
                <th class="text-right">Complaints</th>
                <th class="text-right">Unsubs</th>
                <th class="text-right">Replies</th>
                <th class="text-right">Waiting</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- rows}>
                <td>
                  <.link
                    navigate={~p"/admin/p/#{p.id}/campaigns/#{row.campaign.id}"}
                    class="hover:text-primary"
                  >
                    {row.campaign.name}
                  </.link>
                </td>
                <td class="text-right tabular-nums">{row.sent}</td>
                <td class={["text-right tabular-nums", row.failed > 0 && "text-error"]}>{row.failed}</td>
                <td class="text-right tabular-nums">{row.bounced}</td>
                <td class={["text-right tabular-nums", row.complained > 0 && "text-error font-semibold"]}>
                  {row.complained}
                </td>
                <td class="text-right tabular-nums">{row.unsubscribed}</td>
                <td class="text-right tabular-nums">{row.replies}</td>
                <td class="text-right tabular-nums text-base-content/60">{row.waiting}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :for={t <- @report.tests} id={"test-#{t.project.id}"}>
        <h2 class="font-semibold mb-2">{t.project.name} opener test</h2>
        <div class="card bg-base-100 shadow-sm overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Version</th>
                <th class="text-right">First emails</th>
                <th class="text-right">Positive</th>
                <th class="text-right">Negative</th>
                <th class="text-right">Unsubs</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={v <- t.variants}>
                <td><span class="font-medium">{v.letter}</span> {v.label}</td>
                <td class="text-right tabular-nums">{v.sends}</td>
                <td class="text-right tabular-nums">{v.positive}</td>
                <td class="text-right tabular-nums">{v.negative}</td>
                <td class="text-right tabular-nums">{v.unsubscribed}</td>
              </tr>
            </tbody>
          </table>
          <p class="px-4 py-3 text-sm text-base-content/70 border-t border-base-200">
            {t.verdict}
            <span :if={t.start}>Counting from {Calendar.strftime(t.start, "%b %-d")}.</span>
          </p>
        </div>
      </section>

      <section id="replies">
        <h2 class="font-semibold mb-2">All replies</h2>
        <div :if={@report.replies == []} class="text-sm text-base-content/60">No replies.</div>
        <ul :if={@report.replies != []} class="card bg-base-100 shadow-sm divide-y divide-base-200 text-sm">
          <li :for={r <- @report.replies} class="px-4 py-2 flex gap-3 items-start">
            <span class={["badge badge-sm shrink-0 mt-0.5", tone_class(r.tone)]}>{tone_label(r.tone)}</span>
            <div class="min-w-0">
              <span class="font-medium">{r.company || r.email}</span>
              <span :if={r.campaign} class="text-base-content/50">({r.campaign})</span>
              <div class="text-base-content/70 truncate">“{r.first_line}”</div>
            </div>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <div class="text-lg font-semibold tabular-nums">{@value}</div>
      <div class="text-xs text-base-content/50">{@label}</div>
    </div>
    """
  end

  defp bar(n, days) do
    max = days |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
    max(round(n / max(max, 1) * 100), 4)
  end

  defp tone_class(:hot), do: "badge-success"
  defp tone_class(:negative), do: "badge-error"
  defp tone_class(_), do: "badge-ghost"

  defp tone_label(:hot), do: "Interested"
  defp tone_label(:negative), do: "No"
  defp tone_label(_), do: "Reply"
end
