defmodule ColdForgeWeb.AdminLive.MarketShow do
  @moduledoc """
  One campaign's overview: the numbers, then its searches and email sequences,
  each a click from its own page. Renaming and deleting live here too.

  Deleting a campaign only removes the label. Its searches and sequences stay
  in the project and keep running, listed as "not in a campaign".
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.{Markets, Outreach, Repo, Sourcing}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    market = socket.assigns.current_market
    project = socket.assigns.current_project

    sequences =
      project.id
      |> Outreach.list_campaigns(market_id: market.id)
      |> Repo.preload(:steps)

    socket =
      socket
      |> assign(:page_title, market.name)
      |> assign(:breadcrumbs, [
        {"Projects", ~p"/admin/projects"},
        {project.name, ~p"/admin/p/#{project.id}"}
      ])
      |> assign(:summary, Markets.summary(market))
      |> assign(:sources, Sourcing.list_sources(project_id: project.id, market_id: market.id))
      |> assign(:sequences, sequences)
      |> assign(:stats, Map.new(sequences, &{&1.id, Outreach.campaign_stats(&1.id)}))
      |> assign(:form, to_form(Markets.change_market(market)))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"market" => params}, socket) do
    changeset =
      socket.assigns.current_market
      |> Markets.change_market(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"market" => params}, socket) do
    case Markets.update_market(socket.assigns.current_market, params) do
      {:ok, market} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: ~p"/admin/p/#{market.project_id}/c/#{market.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", _params, socket) do
    market = socket.assigns.current_market
    {:ok, _} = Markets.delete_market(market)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{market.name} deleted. Its searches and emails are still in the project."
     )
     |> push_navigate(to: ~p"/admin/p/#{market.project_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} market={@current_market} current_path={@current_path} />

    <div :if={@live_action == :edit} class="card bg-base-100 shadow-sm mb-6 max-w-xl">
      <div class="card-body">
        <h2 class="card-title text-base">Rename campaign</h2>
        <.form for={@form} id="market-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" />
          <.input field={@form[:notes]} type="textarea" label="Notes (optional)" rows="2" />
          <div class="flex items-center justify-between gap-2">
            <button
              type="button"
              id="delete-market"
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete"
              data-confirm={"Delete #{@current_market.name}? Its searches and emails stay in the project and keep running."}
            >
              Delete campaign
            </button>
            <div class="flex gap-2">
              <.link navigate={@base} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">Save</button>
            </div>
          </div>
        </.form>
      </div>
    </div>

    <div :if={@live_action != :edit} class="flex flex-wrap items-start justify-between gap-2 mb-4">
      <p class="text-sm text-base-content/60 max-w-2xl whitespace-pre-line">
        {@current_market.notes}
      </p>
      <.link navigate={@base <> "/edit"} class="btn btn-ghost btn-sm">
        <.icon name="hero-pencil-square" class="size-4" /> Rename
      </.link>
    </div>

    <div id="market-summary" class="grid grid-cols-3 sm:grid-cols-6 gap-3 mb-6">
      <.tile label="People" value={@summary.people} href={@base <> "/prospects"} />
      <.tile label="Emails sent" value={@summary.sent} href={@base <> "/activity"} />
      <.tile label="Opened" value={pct(@summary.opened, @summary.sent)} href={@base <> "/activity"} />
      <.tile label="Replied" value={@summary.replied} href={@base <> "/replies"} />
      <.tile label="Calls" value={@summary.calls} href={@base <> "/calls"} />
      <.tile label="Postcards" value={@summary.postcards} href={@base <> "/postcards"} />
    </div>

    <div class="grid gap-6 lg:grid-cols-2">
      <div id="market-sources" class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Searches</h2>
            <.link navigate={@base <> "/sourcing/new"} class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="size-4" /> New search
            </.link>
          </div>
          <p :if={@sources == []} class="text-sm text-base-content/60">
            No searches yet. A search finds the businesses this campaign goes after.
          </p>
          <ul class="divide-y divide-base-200">
            <li :for={s <- @sources} class="py-2">
              <.link navigate={@base <> "/sourcing/#{s.id}"} class="font-medium hover:text-primary">
                {s.name}
              </.link>
              <div class="text-xs text-base-content/50">
                {Enum.join(s.segments, ", ")}
                <span :if={s.purpose == "flyers"} class="badge badge-ghost badge-xs ml-1">flyers</span>
              </div>
            </li>
          </ul>
        </div>
      </div>

      <div id="market-sequences" class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Email sequences</h2>
            <.link navigate={@base <> "/campaigns/new"} class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="size-4" /> New sequence
            </.link>
          </div>
          <p :if={@sequences == []} class="text-sm text-base-content/60">
            No emails yet. A sequence is one email, or several with days between them.
          </p>
          <ul class="divide-y divide-base-200">
            <li :for={c <- @sequences} class="py-2 flex items-center justify-between gap-3">
              <div class="min-w-0">
                <.link navigate={@base <> "/campaigns/#{c.id}"} class="font-medium hover:text-primary">
                  {c.name}
                </.link>
                <div class="text-xs text-base-content/50">
                  {length(c.steps)} emails · {@stats[c.id].sent} sent · {@stats[c.id].clicked} clicked
                </div>
              </div>
              <span class={["badge badge-sm shrink-0", status_class(c.status)]}>{c.status}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :href, :string, required: true

  defp tile(assigns) do
    ~H"""
    <.link navigate={@href} class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow">
      <div class="card-body p-4 text-center">
        <div class="text-xl font-semibold tabular-nums">{@value}</div>
        <div class="text-xs text-base-content/50">{@label}</div>
      </div>
    </.link>
    """
  end

  defp pct(_n, 0), do: "–"
  defp pct(n, d), do: "#{round(n * 100 / d)}%"

  defp status_class("active"), do: "badge-success"
  defp status_class("paused"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
