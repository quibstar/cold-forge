defmodule ColdForgeWeb.AdminLive.Markets do
  @moduledoc """
  A project's front page: its campaigns, and starting a new one.

  A campaign is named however it's run — a state, a city, a segment. Searches
  and email sequences that aren't in one yet are listed underneath, each with a
  "move to" choice, so nothing is lost when campaigns are added to a project
  that already has work in it.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Markets
  alias ColdForge.Markets.Market

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok, assign(socket, :project_id, project_id)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, socket.assigns.current_project.name)
      |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
      |> load()

    socket =
      if socket.assigns.live_action == :new,
        do: assign(socket, :form, to_form(Markets.change_market(%Market{}))),
        else: socket

    {:noreply, socket}
  end

  defp load(socket) do
    markets = Markets.list_markets(socket.assigns.project_id)

    socket
    |> assign(:markets, markets)
    |> assign(:summaries, Map.new(markets, &{&1.id, Markets.summary(&1)}))
    |> assign(:unassigned, Markets.unassigned(socket.assigns.project_id))
  end

  @impl true
  def handle_event("validate", %{"market" => params}, socket) do
    changeset = %Market{} |> Markets.change_market(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"market" => params}, socket) do
    case Markets.create_market(Map.put(params, "project_id", socket.assigns.project_id)) do
      {:ok, market} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{market.name} created.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/c/#{market.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("move", %{"kind" => kind, "record_id" => id, "market_id" => market_id}, socket) do
    record =
      case kind do
        "source" -> Enum.find(socket.assigns.unassigned.sources, &(&1.id == id))
        "campaign" -> Enum.find(socket.assigns.unassigned.campaigns, &(&1.id == id))
      end

    if record && market_id != "", do: {:ok, _} = Markets.assign(record, market_id)

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} market={@current_market} current_path={@current_path} />

    <div :if={@live_action == :new} class="card bg-base-100 shadow-sm mb-6 max-w-xl">
      <div class="card-body">
        <h2 class="card-title text-base">New campaign</h2>
        <.form for={@form} id="market-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="Michigan, Grand Rapids, Dog breeders TX…"
          />
          <.input field={@form[:notes]} type="textarea" label="Notes (optional)" rows="2" />
          <div class="flex justify-end gap-2">
            <.link navigate={~p"/admin/p/#{@project_id}"} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Creating…">
              Create campaign
            </button>
          </div>
        </.form>
      </div>
    </div>

    <div :if={@live_action != :new} class="flex justify-end mb-4">
      <.link navigate={~p"/admin/p/#{@project_id}/c/new"} class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="size-4" /> New campaign
      </.link>
    </div>

    <div :if={@markets == [] and @live_action != :new} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-flag" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No campaigns yet</h2>
        <p class="text-base-content/60 max-w-md">
          A campaign is one push: a state, a city or a kind of business. It holds
          its searches, its people, its emails, calls and postcards, and what
          came back.
        </p>
        <.link navigate={~p"/admin/p/#{@project_id}/c/new"} class="btn btn-primary mt-4">
          Create one
        </.link>
      </div>
    </div>

    <div id="markets" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
      <div :for={m <- @markets} id={"market-#{m.id}"} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <.link
            navigate={~p"/admin/p/#{@project_id}/c/#{m.id}"}
            class="font-semibold hover:text-primary truncate"
          >
            {m.name}
          </.link>
          <p class="text-xs text-base-content/50">
            {plural(@summaries[m.id].searches, "search", "searches")} · {plural(
              @summaries[m.id].sequences,
              "email sequence",
              "email sequences"
            )}
            <span :if={@summaries[m.id].active_sequences > 0} class="text-success">
              · {@summaries[m.id].active_sequences} sending
            </span>
          </p>

          <div class="grid grid-cols-4 gap-2 mt-3 text-center">
            <.stat label="People" value={@summaries[m.id].people} />
            <.stat label="Sent" value={@summaries[m.id].sent} />
            <.stat label="Replied" value={@summaries[m.id].replied} />
            <.stat label="Calls" value={@summaries[m.id].calls} />
          </div>
        </div>
      </div>
    </div>

    <div
      :if={@unassigned.sources != [] or @unassigned.campaigns != []}
      id="unassigned"
      class="card bg-base-100 shadow-sm mt-8"
    >
      <div class="card-body">
        <h2 class="card-title text-base">Not in a campaign</h2>
        <p class="text-sm text-base-content/60">
          These still run. Move each into a campaign to see it there.
          <span :if={@markets == []}>Create a campaign first.</span>
        </p>
        <ul class="divide-y divide-base-200 mt-2">
          <li :for={s <- @unassigned.sources} class="flex items-center justify-between gap-3 py-2">
            <.link navigate={~p"/admin/p/#{@project_id}/sourcing/#{s.id}"} class="hover:text-primary">
              <.icon name="hero-magnifying-glass" class="size-4 text-base-content/50" /> {s.name}
            </.link>
            <.move_form :if={@markets != []} kind="source" id={s.id} markets={@markets} />
          </li>
          <li :for={c <- @unassigned.campaigns} class="flex items-center justify-between gap-3 py-2">
            <.link navigate={~p"/admin/p/#{@project_id}/campaigns/#{c.id}"} class="hover:text-primary">
              <.icon name="hero-paper-airplane" class="size-4 text-base-content/50" /> {c.name}
              <span class="badge badge-ghost badge-sm ml-1">{c.status}</span>
            </.link>
            <.move_form :if={@markets != []} kind="campaign" id={c.id} markets={@markets} />
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :id, :string, required: true
  attr :markets, :list, required: true

  defp move_form(assigns) do
    ~H"""
    <form id={"move-#{@kind}-#{@id}"} phx-change="move" class="shrink-0">
      <input type="hidden" name="kind" value={@kind} />
      <input type="hidden" name="record_id" value={@id} />
      <select name="market_id" class="select select-sm" aria-label="Move to campaign">
        <option value="">Move to…</option>
        <option :for={m <- @markets} value={m.id}>{m.name}</option>
      </select>
    </form>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <div class="text-lg font-semibold tabular-nums">{@value}</div>
      <div class="text-xs text-base-content/50">{@label}</div>
    </div>
    """
  end

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(n, _one, many), do: "#{n} #{many}"
end
