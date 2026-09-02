defmodule ColdForgeWeb.AdminLive.Projects do
  @moduledoc """
  Project CRUD. A project carries the sender identity and the landing URL, so
  this form is where the "click goes to my other site" half of the loop is
  configured.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Project

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :projects, Outreach.list_projects())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Projects")
    |> assign(:page_subtitle, "One per idea. Each has its own from-address and landing page.")
    |> assign(:project, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New project")
    |> assign(:page_subtitle, nil)
    |> assign(:project, %Project{})
    |> assign_form(Outreach.change_project(%Project{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Outreach.get_project!(id)

    socket
    |> assign(:page_title, project.name)
    |> assign(:page_subtitle, nil)
    |> assign(:project, project)
    |> assign_form(Outreach.change_project(project))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project
      |> Outreach.change_project(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    project = Outreach.get_project!(id)
    {:ok, _} = Outreach.update_project(project, %{active: not project.active})

    {:noreply, assign(socket, :projects, Outreach.list_projects())}
  end

  defp save(socket, :new, params) do
    case Outreach.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created.")
         |> push_navigate(to: ~p"/admin/p/#{project.id}/prospects")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save(socket, :edit, params) do
    case Outreach.update_project(socket.assigns.project, params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated.")
         |> push_navigate(to: ~p"/admin/projects")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div class="flex justify-end mb-4">
      <.link navigate={~p"/admin/projects/new"} class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="size-4" /> New project
      </.link>
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Project</th>
              <th>From</th>
              <th>Landing page</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@projects == []}>
              <td colspan="4" class="text-center text-base-content/50 py-8">
                No projects yet.
              </td>
            </tr>
            <tr :for={project <- @projects}>
              <td>
                <div class="font-medium">{project.name}</div>
                <div class="text-xs text-base-content/50">/{project.slug}</div>
              </td>
              <td class="text-sm">
                <div>{project.from_name}</div>
                <div class="text-xs text-base-content/50">{project.from_email}</div>
              </td>
              <td class="text-sm max-w-xs truncate">
                <span :if={project.landing_url} class="text-base-content/70">
                  {project.landing_url}
                </span>
                <span :if={is_nil(project.landing_url)} class="text-base-content/40">
                  not set
                </span>
              </td>
              <td class="text-right whitespace-nowrap">
                <button
                  phx-click="toggle_active"
                  phx-value-id={project.id}
                  class={["btn btn-xs", if(project.active, do: "btn-ghost", else: "btn-warning")]}
                >
                  {if project.active, do: "Active", else: "Paused"}
                </button>
                <.link navigate={~p"/admin/projects/#{project.id}/edit"} class="btn btn-xs btn-ghost">
                  Edit
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm max-w-2xl">
      <div class="card-body">
        <.form id="project-form" for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Project name" placeholder="ExteriorPro" />

          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:from_name]} label="From name" placeholder="Kris Utter" />
            <.input
              field={@form[:from_email]}
              label="From email"
              placeholder="kris@exteriorpro.io"
            />
          </div>

          <.input
            field={@form[:reply_to]}
            label="Reply-to (optional)"
            placeholder="Leave blank to use the from address"
          />

          <.input
            field={@form[:landing_url]}
            label="Landing page URL"
            placeholder="https://exteriorpro.io/demo"
          />
          <p class="text-xs text-base-content/50 -mt-2">
            Where <code class="text-primary">{"{{link}}"}</code>
            sends people. Clicks are recorded here first, then redirected out with a <code>?cf=</code>
            parameter so the landing page can attribute the visit.
          </p>

          <.input
            type="textarea"
            field={@form[:postal_address]}
            label="Postal address"
            placeholder="123 Main St, Springfield, IL 62701"
          />
          <p class="text-xs text-base-content/50 -mt-2">
            Appended to every email. CAN-SPAM requires a real physical address in
            commercial mail.
          </p>

          <.input field={@form[:timezone]} label="Timezone" placeholder="America/New_York" />

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/admin/projects"} class="btn btn-ghost">Cancel</.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Save project
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
