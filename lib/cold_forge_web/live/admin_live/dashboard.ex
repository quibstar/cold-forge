defmodule ColdForgeWeb.AdminLive.Dashboard do
  @moduledoc """
  One card per project, each showing the numbers that tell you whether the drip
  is working: prospects, sent, opened, clicked.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach

  @impl true
  def mount(_params, _session, socket) do
    projects = Outreach.list_projects()
    stats = Map.new(projects, &{&1.id, Outreach.project_stats(&1.id)})

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:page_subtitle, "Cold outreach across every project.")
     |> assign(:projects, projects)
     |> assign(:stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@projects == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-squares-2x2" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No projects yet</h2>
        <p class="text-base-content/60 max-w-md">
          A project is one idea: its own sender address, its own landing page,
          its own prospects. Create one to start.
        </p>
        <.link navigate={~p"/admin/projects/new"} class="btn btn-primary mt-4">
          New project
        </.link>
      </div>
    </div>

    <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
      <div :for={project <- @projects} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <.link
                navigate={~p"/admin/p/#{project.id}/campaigns"}
                class="font-semibold hover:text-primary truncate block"
              >
                {project.name}
              </.link>
              <p class="text-xs text-base-content/50 truncate">{project.from_email}</p>
            </div>
            <span :if={not project.active} class="badge badge-ghost badge-sm shrink-0">Paused</span>
          </div>

          <div class="grid grid-cols-4 gap-2 mt-4 text-center">
            <.stat label="People" value={@stats[project.id].prospects} />
            <.stat label="Sent" value={@stats[project.id].sent} />
            <.stat label="Opened" value={@stats[project.id].opened} />
            <.stat label="Clicked" value={@stats[project.id].clicked} />
          </div>

          <div class="card-actions justify-end mt-4">
            <.link
              navigate={~p"/admin/p/#{project.id}/prospects"}
              class="btn btn-sm btn-ghost"
            >
              Prospects
            </.link>
            <.link
              navigate={~p"/admin/p/#{project.id}/campaigns"}
              class="btn btn-sm btn-primary"
            >
              Campaigns
            </.link>
          </div>
        </div>
      </div>
    </div>
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
end
