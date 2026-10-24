defmodule ColdForgeWeb.AdminLive.Calls do
  @moduledoc """
  The call queue: who to ring now, who is booked for later, and what happened.

  A list and nothing else. Picking somebody opens their own page — see
  `ColdForgeWeb.AdminLive.CallProspect` — which is where the script, the form
  and the history live.

  It used to open their panel beside the queue instead, on the theory that
  calling is done in a run and a page load between calls is friction. That was
  right about the run and wrong about the panel: the thing being opened is a
  page of hand-written script plus a debrief form, and a column sized for a
  summary card could not hold it. Below the `lg` breakpoint the panel rendered
  underneath fifty queue rows, so clicking a prospect looked like nothing
  happening at all.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Calling
  alias ColdForge.Calling.Call
  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, socket.assigns.current_project.name)
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
     |> assign(:trade, "")
     |> assign(:page, 1)
     |> load()}
  end

  @impl true
  def handle_event("trade", params, socket) do
    {:noreply,
     socket
     |> assign(:trade, Map.get(params, "trade", ""))
     |> assign(:page, 1)
     |> load()}
  end

  @impl true
  def handle_event("page", %{"to" => to}, socket) do
    page =
      case to do
        "next" -> socket.assigns.page + 1
        "prev" -> socket.assigns.page - 1
        n -> String.to_integer(n)
      end

    {:noreply, socket |> assign(:page, page) |> load()}
  end

  defp load(socket) do
    project_id = socket.assigns.project_id
    trade = socket.assigns.trade
    pages = Calling.queue_page_count(project_id, trade: trade)
    # Clamped, so a stale page number left over from a filter change can't show
    # an empty list with rows still waiting.
    page = socket.assigns.page |> min(pages) |> max(1)

    socket
    |> assign(:page, page)
    |> assign(:pages, pages)
    |> assign(:queue_total, Calling.queue_size(project_id, trade: trade))
    |> assign(:trades, Outreach.list_trades(project_id))
    |> assign(:queue, Calling.queue(project_id, page: page, trade: trade))
    |> assign(:scheduled, Calling.scheduled(project_id, limit: 10, trade: trade))
    |> assign(:recent, Calling.recent_calls(project_id, 10))
    |> assign(:stats, Calling.stats(project_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div :if={@current_project.phone in [nil, ""]} class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <span>
        No callback number set for this project, so the voicemail scripts can't be
        filled in — a voicemail without a number to ring back is a wasted call.
        <.link navigate={~p"/admin/projects/#{@project_id}/edit"} class="link">
          Add one
        </.link>
      </span>
    </div>

    <form :if={length(@trades) > 1} id="call-trade-filter" phx-change="trade" class="mb-2 max-w-md">
      <.input
        type="choice"
        id="call-trade"
        name="trade"
        value={@trade}
        prompt="All trades"
        options={Enum.map(@trades, &{"#{&1.label} (#{&1.count})", &1.key})}
      />
    </form>

    <div class="grid gap-3 sm:grid-cols-4 mb-4">
      <.stat label="Calls made" value={@stats.calls} />
      <.stat label="Voicemails" value={@stats.voicemails} />
      <.stat label="Conversations" value={@stats.conversations} />
      <.stat label="Interested" value={@stats.interested} tone="text-primary" />
    </div>

    <div class="grid gap-4 lg:grid-cols-3">
      <div class="lg:col-span-2 space-y-4">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              Call now <span class="badge badge-sm badge-ghost">{@queue_total}</span>
            </h2>

            <p :if={@queue == []} class="text-sm text-base-content/50">
              Nobody due. Either everyone has been called and is waiting on their
              next slot, or no prospect on this project has a phone number yet.
            </p>

            <ul id="call-queue" class="divide-y divide-base-200">
              <li :for={p <- @queue} class="py-2">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/calls/#{p.id}"}
                  id={"queue-#{p.id}"}
                  class="block rounded-lg px-2 py-1.5 hover:bg-base-200 transition-colors"
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="min-w-0">
                      <span class="block font-medium truncate">{Prospect.display_name(p)}</span>
                      <span class="block text-xs text-base-content/50 truncate">
                        {queue_subtitle(p)}
                      </span>
                    </span>
                    <span class="flex items-center gap-1.5 shrink-0">
                      <%!-- The grade the list gave them, and what the queue is
                      ordered by once nobody has been called yet. --%>
                      <span :if={Prospect.fit(p)} class={["badge badge-xs", fit_tone(p)]}>
                        {Prospect.fit(p)}
                      </span>
                      <span :if={not Prospect.dialable?(p)} class="badge badge-xs badge-warning">
                        no number
                      </span>
                      <span class="text-xs text-base-content/40">{attempt_label(p)}</span>
                    </span>
                  </div>
                </.link>
              </li>
            </ul>

            <%!-- Only when there is more than one page. A pager under a list of
                  six rows is furniture. --%>
            <div
              :if={@pages > 1}
              class="flex items-center justify-between gap-3 pt-3 border-t border-base-200"
            >
              <p class="text-xs text-base-content/60">
                {(@page - 1) * Calling.per_page() + 1}–{min(@page * Calling.per_page(), @queue_total)} of {@queue_total}
              </p>

              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="btn btn-xs btn-ghost"
                  phx-click="page"
                  phx-value-to="prev"
                  disabled={@page <= 1}
                >
                  Previous
                </button>
                <span class="text-xs text-base-content/60">Page {@page} of {@pages}</span>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost"
                  phx-click="page"
                  phx-value-to="next"
                  disabled={@page >= @pages}
                >
                  Next
                </button>
              </div>
            </div>
          </div>
        </div>

        <div :if={@scheduled != []} class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Coming up</h2>
            <ul class="space-y-1 text-sm">
              <li :for={p <- @scheduled} class="flex justify-between gap-2">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/calls/#{p.id}"}
                  class="truncate hover:underline"
                >
                  {Prospect.display_name(p)}
                </.link>
                <span class="text-base-content/50 shrink-0">
                  {Calendar.strftime(p.next_call_at, "%b %-d")}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm h-fit">
        <div class="card-body">
          <h2 class="card-title text-base">Recent calls</h2>
          <p :if={@recent == []} class="text-sm text-base-content/50">Nothing logged yet.</p>
          <ul class="space-y-2">
            <li :for={c <- @recent} class="text-sm border-b border-base-200 pb-2 last:border-0">
              <div class="flex justify-between gap-2">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/calls/#{c.prospect.id}"}
                  class="truncate hover:underline"
                >
                  {Prospect.display_name(c.prospect)}
                </.link>
                <span class="text-xs text-base-content/50 shrink-0">
                  {Calendar.strftime(c.called_at, "%b %-d")}
                </span>
              </div>
              <div class="text-xs text-base-content/60">{Call.label(c.outcome)}</div>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, default: ""

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body py-4 items-center">
        <div class={["text-2xl font-bold tabular-nums", @tone]}>{@value}</div>
        <div class="text-xs text-base-content/50">{@label}</div>
      </div>
    </div>
    """
  end

  # Everything under the name that is worth a glance before dialling: the
  # number, and where they are. `display_name/1` already falls back to the
  # company for a prospect with no contact name, which most of a bought or
  # hand-built call sheet is, so repeating it here would print it twice.
  defp queue_subtitle(prospect) do
    [prospect.phone, Prospect.custom_field(prospect, "city")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp fit_tone(prospect) do
    case prospect |> Prospect.fit() |> Prospect.fit_rank() do
      0 -> "badge-primary"
      1 -> "badge-ghost"
      _ -> "badge-ghost opacity-60"
    end
  end

  defp attempt_label(%{call_attempts: 0}), do: "never called"
  defp attempt_label(%{call_attempts: 1}), do: "1 attempt"
  defp attempt_label(%{call_attempts: n}), do: "#{n} attempts"
end
