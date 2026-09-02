defmodule ColdForgeWeb.AdminLive.Calls do
  @moduledoc """
  The call queue: who to ring now, what to say, and what happened.

  Built as one screen because calling is done in a run — pick up the phone,
  work down the list — and a workflow that needs a page load between each call
  is one nobody uses twice. Selecting somebody opens their panel beside the
  queue rather than navigating away from it.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.{Calling, Outreach}
  alias ColdForge.Calling.{Call, Scripts}
  alias ColdForge.Outreach.Prospect

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, socket.assigns.current_project.name)
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
     |> assign(:selected, nil)
     |> assign(:notes, "")
     |> load()}
  end

  defp load(socket) do
    project_id = socket.assigns.project_id

    socket
    |> assign(:queue, Calling.queue(project_id))
    |> assign(:scheduled, Calling.scheduled(project_id, limit: 10))
    |> assign(:recent, Calling.recent_calls(project_id, 10))
    |> assign(:stats, Calling.stats(project_id))
  end

  defp select(socket, prospect) do
    socket
    |> assign(:selected, prospect)
    |> assign(:history, Calling.list_calls(prospect.id))
    |> assign(:next_script, Calling.next_script(prospect.id))
    |> assign(:notes, "")
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, select(socket, Outreach.get_prospect!(id))}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  def handle_event("notes", %{"notes" => notes}, socket) do
    {:noreply, assign(socket, :notes, notes)}
  end

  def handle_event("log", %{"outcome" => outcome} = params, socket) do
    prospect = socket.assigns.selected

    {:ok, _call} =
      Calling.log_call(prospect, %{
        "outcome" => outcome,
        "notes" => socket.assigns.notes,
        "voicemail_script" => params["script"]
      })

    {:noreply,
     socket
     |> put_flash(:info, "#{Call.label(outcome)} — #{Prospect.display_name(prospect)}")
     |> assign(:selected, nil)
     |> load()}
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
              Call now <span class="badge badge-sm badge-ghost">{length(@queue)}</span>
            </h2>

            <p :if={@queue == []} class="text-sm text-base-content/50">
              Nobody due. Either everyone has been called and is waiting on their
              next slot, or no prospect on this project has a phone number yet.
            </p>

            <ul class="divide-y divide-base-200">
              <li :for={p <- @queue} class="py-2">
                <button
                  phx-click="select"
                  phx-value-id={p.id}
                  class={[
                    "w-full text-left rounded-lg px-2 py-1.5 hover:bg-base-200 transition-colors",
                    @selected && @selected.id == p.id && "bg-primary/10"
                  ]}
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="min-w-0">
                      <span class="block font-medium truncate">{Prospect.display_name(p)}</span>
                      <span class="block text-xs text-base-content/50 truncate">
                        {p.company} · {p.phone}
                      </span>
                    </span>
                    <span class="text-xs text-base-content/40 shrink-0">
                      {attempt_label(p)}
                    </span>
                  </div>
                </button>
              </li>
            </ul>
          </div>
        </div>

        <div :if={@scheduled != []} class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Coming up</h2>
            <ul class="space-y-1 text-sm">
              <li :for={p <- @scheduled} class="flex justify-between gap-2">
                <span class="truncate">{Prospect.display_name(p)}</span>
                <span class="text-base-content/50 shrink-0">
                  {Calendar.strftime(p.next_call_at, "%b %-d")}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <.call_panel
        :if={@selected}
        prospect={@selected}
        project={@current_project}
        history={@history}
        next_script={@next_script}
        notes={@notes}
      />

      <div :if={is_nil(@selected)} class="card bg-base-100 shadow-sm h-fit">
        <div class="card-body">
          <h2 class="card-title text-base">Recent calls</h2>
          <p :if={@recent == []} class="text-sm text-base-content/50">Nothing logged yet.</p>
          <ul class="space-y-2">
            <li :for={c <- @recent} class="text-sm border-b border-base-200 pb-2 last:border-0">
              <div class="flex justify-between gap-2">
                <span class="truncate">{Prospect.display_name(c.prospect)}</span>
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

  attr :prospect, :map, required: true
  attr :project, :map, required: true
  attr :history, :list, required: true
  attr :next_script, :integer, default: nil
  attr :notes, :string, default: ""

  defp call_panel(assigns) do
    assigns =
      assign(
        assigns,
        :script,
        Scripts.render(assigns.next_script, assigns.prospect, assigns.project)
      )

    ~H"""
    <div class="card bg-base-100 shadow-sm h-fit lg:sticky lg:top-20">
      <div class="card-body">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <h2 class="card-title text-base">{Prospect.display_name(@prospect)}</h2>
            <p class="text-sm text-base-content/60 truncate">
              {@prospect.company}
              <span :if={@prospect.title}>· {@prospect.title}</span>
            </p>
          </div>
          <button phx-click="deselect" class="btn btn-xs btn-ghost" aria-label="Close">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%!-- A tel: link so this works from a phone or a softphone rather than
        making somebody retype a number they are looking straight at. --%>
        <a href={"tel:#{@prospect.phone}"} class="btn btn-primary btn-sm mt-1">
          <.icon name="hero-phone" class="size-4" /> {@prospect.phone}
        </a>

        <div :if={@script} class="mt-3">
          <div class="text-xs text-base-content/40">
            Voicemail {@next_script} — {script_note(@next_script)}
          </div>
          <p class="text-sm bg-base-200 rounded-lg p-3 mt-1 whitespace-pre-line">{@script}</p>
        </div>

        <p :if={is_nil(@next_script)} class="text-xs text-base-content/50 mt-3">
          All four voicemails have been left. There is no fifth message that helps —
          this is a call to have or a file to close.
        </p>

        <form phx-change="notes" class="mt-3">
          <textarea
            name="notes"
            rows="2"
            placeholder="What did they say?"
            phx-debounce="300"
            class="textarea w-full text-sm"
          >{@notes}</textarea>
        </form>

        <div class="grid grid-cols-2 gap-2 mt-2">
          <button
            :if={@next_script}
            phx-click="log"
            phx-value-outcome="voicemail"
            phx-value-script={@next_script}
            class="btn btn-sm"
          >
            Left voicemail {@next_script}
          </button>
          <button phx-click="log" phx-value-outcome="no_answer" class="btn btn-sm">
            No answer
          </button>
          <button phx-click="log" phx-value-outcome="connected" class="btn btn-sm">
            Spoke to them
          </button>
          <button phx-click="log" phx-value-outcome="interested" class="btn btn-sm btn-primary">
            Interested
          </button>
          <button phx-click="log" phx-value-outcome="not_now" class="btn btn-sm btn-ghost">
            Not now
          </button>
          <button phx-click="log" phx-value-outcome="not_interested" class="btn btn-sm btn-ghost">
            Not interested
          </button>
          <button phx-click="log" phx-value-outcome="wrong_number" class="btn btn-sm btn-ghost">
            Wrong number
          </button>
          <button
            phx-click="log"
            phx-value-outcome="do_not_call"
            data-confirm="This stops calls and emails for them, everywhere. Continue?"
            class="btn btn-sm btn-ghost text-error"
          >
            Do not call
          </button>
        </div>

        <div :if={@history != []} class="mt-3 pt-3 border-t border-base-200">
          <div class="text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-1">
            History
          </div>
          <ul class="space-y-1 text-xs">
            <li :for={c <- @history} class="text-base-content/60">
              {Calendar.strftime(c.called_at, "%b %-d")} — {Call.label(c.outcome)}
              <span :if={c.notes not in [nil, ""]} class="block text-base-content/50 pl-3">
                {c.notes}
              </span>
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

  defp attempt_label(%{call_attempts: 0}), do: "never called"
  defp attempt_label(%{call_attempts: 1}), do: "1 attempt"
  defp attempt_label(%{call_attempts: n}), do: "#{n} attempts"

  defp script_note(number) do
    {_, note} = Enum.find(Scripts.catalogue(), fn {n, _} -> n == number end)
    note
  end
end
