defmodule ColdForgeWeb.AdminLive.Report do
  @moduledoc """
  The daily review on a page: interested replies first, then sending-address
  health, each project's drips for the last sending day, and any opener test.
  The same numbers the morning email sends; see `ColdForge.Reports`.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.{Outreach, Reports}

  @ranges [
    {"Last sending day", "last_day"},
    {"Last 7 days", "7d"},
    {"Last 30 days", "30d"},
    {"This month", "month"},
    {"Last month", "last_month"},
    {"Custom dates", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Daily report")
     |> assign(:ranges, @ranges)
     |> assign(:projects, Outreach.list_projects() |> Enum.filter(& &1.active))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    today = Reports.local_today()

    range =
      if params["range"] in Enum.map(@ranges, &elem(&1, 1)), do: params["range"], else: "last_day"

    window = window(range, params, today)

    project_id =
      Enum.find_value(socket.assigns.projects, fn p -> p.id == params["project"] && p.id end)

    report =
      Reports.report(window,
        today: today,
        project_id: project_id,
        slow: range == "last_day"
      )

    {:noreply,
     socket
     |> assign(:page_subtitle, Reports.window_label(window) <> ": " <> report.status)
     |> assign(:report, report)
     |> assign(:range, range)
     |> assign(:project_id, project_id)
     |> assign(:from, Date.to_iso8601(window.first))
     |> assign(:to, Date.to_iso8601(window.last))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{"range" => params["range"], "project" => params["project"]}
      |> then(fn q ->
        if params["range"] == "custom",
          do: Map.merge(q, %{"from" => params["from"], "to" => params["to"]}),
          else: q
      end)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/admin/report?#{query}")}
  end

  defp window("7d", _params, today), do: Reports.range(Date.add(today, -7), Date.add(today, -1))
  defp window("30d", _params, today), do: Reports.range(Date.add(today, -30), Date.add(today, -1))
  defp window("month", _params, today), do: Reports.range(Date.beginning_of_month(today), today)

  defp window("last_month", _params, today) do
    last = today |> Date.beginning_of_month() |> Date.add(-1)
    Reports.range(Date.beginning_of_month(last), last)
  end

  defp window("custom", params, today) do
    yesterday = Date.add(today, -1)
    Reports.range(parse_date(params["from"], yesterday), parse_date(params["to"], yesterday))
  end

  defp window(_last_day, _params, today), do: Reports.window(today)

  defp parse_date(value, default) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> date
      _ -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <form
        id="report-filters"
        phx-change="filter"
        class="card bg-base-100 shadow-sm"
      >
        <div class="card-body py-4 flex flex-col sm:flex-row sm:flex-wrap sm:items-end gap-3">
          <label class="form-control">
            <span class="label-text text-xs text-base-content/60 mb-1">Period</span>
            <select name="range" class="select select-sm select-bordered">
              <option :for={{label, value} <- @ranges} value={value} selected={value == @range}>
                {label}
              </option>
            </select>
          </label>
          <label :if={@range == "custom"} class="form-control">
            <span class="label-text text-xs text-base-content/60 mb-1">From</span>
            <input type="date" name="from" value={@from} class="input input-sm input-bordered" />
          </label>
          <label :if={@range == "custom"} class="form-control">
            <span class="label-text text-xs text-base-content/60 mb-1">To</span>
            <input type="date" name="to" value={@to} class="input input-sm input-bordered" />
          </label>
          <label class="form-control">
            <span class="label-text text-xs text-base-content/60 mb-1">Project</span>
            <select name="project" class="select select-sm select-bordered">
              <option value="">All projects</option>
              <option :for={p <- @projects} value={p.id} selected={p.id == @project_id}>
                {p.name}
              </option>
            </select>
          </label>
        </div>
      </form>

      <div
        :if={@report.hot != []}
        id="hot-replies"
        class="card bg-success/10 border border-success/30"
      >
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
              Now {row.campaign.daily_cap} a day, ramping to {row.campaign.max_daily_cap ||
                "no ceiling"}.
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
                  <div class="text-xs text-base-content/50 truncate">
                    {Enum.join(a.projects, ", ")}
                  </div>
                </div>
                <span :if={a.warnings == []} class="badge badge-success badge-sm shrink-0">Healthy</span>
                <span :if={a.warnings != []} class="badge badge-warning badge-sm shrink-0">Check</span>
              </div>

              <div class="grid grid-cols-4 gap-2 mt-3 text-center">
                <.stat label="Sent" value={a.sent} />
                <.stat label="Bounced" value={a.bounced} />
                <.stat label="Complaints" value={a.complaints} />
                <.stat label="Bounce rate" value={Reports.pct(a.rate)} />
              </div>

              <div
                :if={a.days != []}
                class="mt-3 flex items-end gap-1 h-12"
                aria-label="Sends per day"
              >
                <div
                  :for={{d, n} <- a.days}
                  class="flex-1 bg-primary/40 rounded-t"
                  style={"height: #{bar(n, a.days)}%"}
                  title={"#{Calendar.strftime(d, "%a %b %-d")}: #{n}"}
                >
                </div>
              </div>

              <p class="mt-2 text-xs text-base-content/50">
                Last 7 days to {Calendar.strftime(@report.window.last, "%b %-d")}: {a.week_sent} sent, {Reports.pct(
                  a.week_rate
                )} bounced, {a.week_complaints} complaints.
              </p>

              <ul :if={a.warnings != []} class="mt-3 text-sm text-warning-content space-y-1">
                <li :for={w <- a.warnings} class="flex gap-2">
                  <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 mt-0.5 text-warning" /> {w}
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      <section
        :for={%{project: p, rows: rows} <- @report.projects}
        :if={rows != []}
        id={"project-#{p.id}"}
      >
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
                <td class={["text-right tabular-nums", row.failed > 0 && "text-error"]}>
                  {row.failed}
                </td>
                <td class="text-right tabular-nums">{row.bounced}</td>
                <td class={[
                  "text-right tabular-nums",
                  row.complained > 0 && "text-error font-semibold"
                ]}>
                  {row.complained}
                </td>
                <td class="text-right tabular-nums">{row.unsubscribed}</td>
                <td class="text-right tabular-nums">{row.replies}</td>
                <td class="text-right tabular-nums text-base-content/60">{row.waiting}</td>
              </tr>
            </tbody>
            <tfoot :if={length(rows) > 1}>
              <tr class="font-semibold">
                <td>Total</td>
                <td
                  :for={
                    key <- [:sent, :failed, :bounced, :complained, :unsubscribed, :replies, :waiting]
                  }
                  class="text-right tabular-nums"
                >
                  {rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()}
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      </section>

      <section :for={t <- @report.tests} id={"test-#{t.project.id}"}>
        <h2 class="font-semibold mb-2">{t.project.name} opener test, to date</h2>
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
        <h2 class="font-semibold mb-2">All replies ({length(@report.replies)})</h2>
        <div :if={@report.replies == []} class="text-sm text-base-content/60">No replies.</div>
        <ul
          :if={@report.replies != []}
          class="card bg-base-100 shadow-sm divide-y divide-base-200 text-sm"
        >
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
