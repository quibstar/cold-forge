defmodule ColdForgeWeb.AdminLive.DoNotContact do
  @moduledoc """
  A project's do-not-contact list. Adding a company stops it everywhere at
  once — campaigns, calls, postcards — and keeps it from being added again by
  a search, an import or by hand. See `ColdForge.DoNotContact`.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.DoNotContact
  alias ColdForge.DoNotContact.Entry

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, "Do not contact")
     |> assign(:breadcrumbs, [
       {"Projects", ~p"/admin/projects"},
       {"Prospects", ~p"/admin/p/#{project_id}/prospects"}
     ])
     |> assign(:form, to_form(DoNotContact.change(%Entry{}), as: :entry))
     |> load()}
  end

  defp load(socket) do
    project_id = socket.assigns.project_id

    socket
    |> assign(:entries, DoNotContact.list(project_id))
    |> assign(:caught, DoNotContact.caught(project_id))
  end

  @impl true
  def handle_event("validate", %{"entry" => params}, socket) do
    form =
      %Entry{}
      |> DoNotContact.change(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :entry)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("add", %{"entry" => params}, socket) do
    case DoNotContact.add(socket.assigns.project_id, params) do
      {:ok, {entry, caught}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(DoNotContact.change(%Entry{}), as: :entry))
         |> put_flash(:info, added_message(entry, caught))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :entry))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    entry = Enum.find(socket.assigns.entries, &(&1.id == id))
    {:ok, _} = DoNotContact.remove(entry)
    {:noreply, socket |> put_flash(:info, "Took #{entry.name} off the list.") |> load()}
  end

  defp added_message(entry, 0), do: "Added #{entry.name}. No prospects matched."

  defp added_message(entry, n),
    do: "Added #{entry.name}. Stopped #{n} #{if n == 1, do: "prospect", else: "prospects"}."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid gap-4 max-w-3xl">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">Do not contact</h2>
          <p class="text-xs opacity-60 -mt-1">
            Companies this project never emails, calls or mails. Adding one stops its
            campaigns, puts its address on the do-not-email list, and logs a
            "Not interested" call so it leaves the call queue. It can't be added again by a
            search, an import or by hand. A name covers any company whose name starts with
            it; a website catches the company under any name.
          </p>

          <.form
            for={@form}
            id="dnc-form"
            phx-change="validate"
            phx-submit="add"
            class="grid gap-2 sm:grid-cols-[2fr_2fr_auto] items-end"
          >
            <.input field={@form[:name]} label="Company" placeholder="High Point Roofing" />
            <.input
              field={@form[:domain]}
              label="Website (optional)"
              placeholder="highpointroofingmi.com"
            />
            <button type="submit" class="btn btn-sm mb-2" phx-disable-with="Adding…">Add</button>
          </.form>

          <p :if={@entries == []} class="text-sm opacity-60">Nobody on the list.</p>

          <table :if={@entries != []} class="table table-sm" id="dnc-entries">
            <thead>
              <tr>
                <th>Company</th>
                <th>Website</th>
                <th>Added</th>
                <th class="w-8"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @entries} id={"dnc-#{e.id}"}>
                <td class="font-medium">{e.name}</td>
                <td class="text-xs opacity-70">{e.domain}</td>
                <td class="text-xs opacity-60">{Calendar.strftime(e.inserted_at, "%b %-d, %Y")}</td>
                <td>
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost text-error"
                    phx-click="remove"
                    phx-value-id={e.id}
                    data-confirm={"Take #{e.name} off the list? Prospects it stopped stay stopped."}
                    aria-label={"Take #{e.name} off the list"}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@caught != []} class="card bg-base-100 shadow-sm">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">Prospects on file that it covers</h2>
          <p class="text-xs opacity-60 -mt-1">
            Kept so the history of what was sent stays. None of them will be contacted.
          </p>
          <ul class="text-sm grid gap-1" id="dnc-caught">
            <li :for={p <- @caught}>
              <.link
                navigate={~p"/admin/p/#{@project_id}/prospects/#{p.id}/edit"}
                class="hover:text-primary"
              >
                {p.company || p.email}
              </.link>
              <span class="text-xs opacity-50">{p.website || p.email}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
