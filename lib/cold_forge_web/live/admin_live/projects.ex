defmodule ColdForgeWeb.AdminLive.Projects do
  @moduledoc """
  Project CRUD. A project carries the sender identity and the landing URL, so
  this form is where the "click goes to my other site" half of the loop is
  configured.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Project

  # 2 MB is generous for a logo and well under what a mail client will happily
  # inline. PNG and JPG only — Gmail and Outlook don't render SVG.
  @logo_max_bytes 2_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:projects, Outreach.list_projects())
     |> allow_upload(:logo,
       accept: ~w(.png .jpg .jpeg),
       max_entries: 1,
       max_file_size: @logo_max_bytes
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Projects")
    |> assign(:page_subtitle, "One per idea. Each has its own from-address and landing page.")
    # Reset explicitly: this LiveView also serves new/edit, and their trail
    # would otherwise linger after navigating back to the list.
    |> assign(:breadcrumbs, [])
    |> assign(:project, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New project")
    |> assign(:page_subtitle, nil)
    |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
    |> assign(:project, %Project{})
    |> assign_form(Outreach.change_project(%Project{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Outreach.get_project!(id)

    socket
    |> assign(:page_title, project.name)
    |> assign(:page_subtitle, nil)
    |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
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
    params =
      case consume_logo(socket) do
        nil -> params
        path -> Map.put(params, "logo_path", path)
      end

    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("remove_logo", _params, socket) do
    {:ok, project} = Outreach.update_project(socket.assigns.project, %{logo_path: nil})

    {:noreply,
     socket
     |> assign(:project, project)
     |> assign_form(Outreach.change_project(project))}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    project = Outreach.get_project!(id)
    {:ok, _} = Outreach.update_project(project, %{active: not project.active})

    {:noreply, assign(socket, :projects, Outreach.list_projects())}
  end

  # Written under priv/static so a mail client can fetch it without a session.
  # The name carries a random suffix rather than the original filename: two
  # projects uploading "logo.png" must not collide, and a filename from an
  # upload is not something to trust as a path.
  defp consume_logo(socket) do
    socket
    |> consume_uploaded_entries(:logo, fn %{path: tmp_path}, entry ->
      ext = Path.extname(entry.client_name) |> String.downcase()
      name = "#{Ecto.UUID.generate()}#{ext}"
      dest_dir = Path.join([:code.priv_dir(:cold_forge), "static", "uploads", "logos"])
      File.mkdir_p!(dest_dir)
      File.cp!(tmp_path, Path.join(dest_dir, name))
      {:ok, "/uploads/logos/#{name}"}
    end)
    |> List.first()
  end

  # Multi-line placeholders come from functions rather than inline strings.
  # In HEEx a plain attribute is literal text — `placeholder="a\nb"` shows a
  # backslash and an n — and `mix format` rewrites the `{"a\nb"}` form that
  # would fix it straight back into the broken one. A function call it leaves
  # alone.
  defp signature_hint, do: "Kris Utter\nExteriorPro\n(555) 123-4567"

  defp merge_defaults_hint, do: "industry: contractors\nproduct: ExteriorPro"

  defp logo_error(:too_large), do: "That image is over 2 MB."
  defp logo_error(:not_accepted), do: "PNG or JPG only."
  defp logo_error(:too_many_files), do: "One logo at a time."
  defp logo_error(error), do: to_string(error)

  defp save(socket, :new, params) do
    case Outreach.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created.")
         |> push_navigate(to: ~p"/admin/p/#{project.id}")}

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
                <.link navigate={~p"/admin/p/#{project.id}"} class="font-medium hover:text-primary">
                  {project.name}
                </.link>
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
    <div class="card bg-base-100 shadow-sm">
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

          <%!-- The broadest level of the merge chain. A campaign default beats
          this, and a prospect's own value beats both. --%>
          <div>
            <label class="text-sm font-medium">Default values</label>
            <textarea
              name="project[merge_defaults_text]"
              rows="3"
              placeholder={merge_defaults_hint()}
              class="textarea w-full mt-1 font-mono text-sm"
            >{ColdForge.MergeFields.to_text(@form[:merge_defaults].value)}</textarea>
            <p class="text-xs text-base-content/50 mt-1">
              One per line, <code>name: value</code>. Anything true of every campaign
              for this idea. A campaign can override it, and a prospect's own value
              overrides both.
            </p>
          </div>

          <div class="divider text-xs text-base-content/40">Branding</div>

          <.input
            type="textarea"
            field={@form[:signature]}
            label="Signature"
            rows="4"
            placeholder={signature_hint()}
          />
          <p class="text-xs text-base-content/50 -mt-2">
            Added above the unsubscribe footer on every send. In cold email this is
            the branding that works — a sign-off from a person, not a letterhead.
          </p>

          <div>
            <label class="text-sm font-medium">Logo</label>

            <div :if={@project && @project.logo_path} class="flex items-center gap-3 mt-2">
              <%!-- On a white swatch because that's the header it lands on in
              the email, not the admin's background. --%>
              <div class="bg-white rounded-lg p-2 border border-base-300">
                <img src={@project.logo_path} alt="" class="max-h-12 max-w-[10rem]" />
              </div>
              <button type="button" phx-click="remove_logo" class="btn btn-xs btn-ghost text-error">
                Remove
              </button>
            </div>

            <label
              class="flex items-center justify-center gap-2 border-2 border-dashed border-base-300 rounded-lg py-6 mt-2 cursor-pointer hover:border-primary/50 transition-colors"
              phx-drop-target={@uploads.logo.ref}
            >
              <.icon name="hero-arrow-up-tray" class="size-5 text-base-content/40" />
              <span class="text-sm text-base-content/60">
                {if @project && @project.logo_path, do: "Replace logo", else: "Upload a logo"}
              </span>
              <.live_file_input upload={@uploads.logo} class="sr-only" />
            </label>

            <div :for={entry <- @uploads.logo.entries} class="mt-2 text-sm">
              <div class="flex items-center justify-between">
                <span class="truncate">{entry.client_name}</span>
                <span class="text-base-content/50">{entry.progress}%</span>
              </div>
              <p :for={err <- upload_errors(@uploads.logo, entry)} class="text-error text-xs mt-1">
                {logo_error(err)}
              </p>
            </div>

            <p class="text-xs text-base-content/50 mt-2">
              PNG or JPG, up to 2 MB. Not SVG — Gmail and Outlook won't render it.
            </p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:logo_url]}
              label="…or a logo URL"
              placeholder="https://exteriorpro.io/logo.png"
            />
            <.input field={@form[:brand_color]} label="Brand colour" placeholder="#0f766e" />
          </div>
          <p class="text-xs text-base-content/50 -mt-2">
            Used only by campaigns with branded HTML turned on. Cold campaigns stay
            plain — a designed template is the clearest signal that mail was sent in
            bulk, and it costs you the Primary tab. An uploaded logo wins over a URL.
          </p>

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
