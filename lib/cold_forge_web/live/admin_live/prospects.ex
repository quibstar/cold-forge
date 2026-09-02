defmodule ColdForgeWeb.AdminLive.Prospects do
  @moduledoc """
  The prospect list for one project, with search and a status filter.

  Status is shown prominently because it's what decides whether someone will be
  mailed again — a list that hides "unsubscribed" invites you to re-add them.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:search, "")
     |> assign(:status, "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> apply_action(socket.assigns.live_action, params)
     |> load_prospects()}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, socket.assigns.current_project.name)
    |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
    |> assign(:prospect, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New prospect")
    |> assign(:breadcrumbs, prospect_crumbs(socket))
    |> assign(:prospect, %Prospect{})
    |> assign_form(Outreach.change_prospect(%Prospect{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    prospect = Outreach.get_prospect!(id)

    socket
    |> assign(:page_title, Prospect.display_name(prospect))
    |> assign(:breadcrumbs, prospect_crumbs(socket))
    |> assign(:prospect, prospect)
    |> assign(:messages, Outreach.list_messages_for_prospect(prospect.id))
    |> assign_form(Outreach.change_prospect(prospect))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp prospect_crumbs(socket) do
    [
      {"Projects", ~p"/admin/projects"},
      {socket.assigns.current_project.name, ~p"/admin/p/#{socket.assigns.project_id}/prospects"}
    ]
  end

  defp load_prospects(socket) do
    prospects =
      Outreach.list_prospects(socket.assigns.project_id,
        search: socket.assigns.search,
        status: socket.assigns.status
      )

    socket
    |> assign(:prospects, prospects)
    |> assign(:counts, Outreach.count_prospects_by_status(socket.assigns.project_id))
  end

  @impl true
  def handle_event("filter", %{"search" => search, "status" => status}, socket) do
    {:noreply,
     socket
     |> assign(search: search, status: status)
     |> load_prospects()}
  end

  def handle_event("validate", %{"prospect" => params}, socket) do
    changeset =
      socket.assigns.prospect
      |> Outreach.change_prospect(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"prospect" => params}, socket) do
    params = Map.put(params, "project_id", socket.assigns.project_id)
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("unsubscribe", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_prospect!() |> Outreach.unsubscribe_prospect()

    {:noreply,
     socket
     |> put_flash(:info, "Unsubscribed and added to the do-not-contact list.")
     |> load_prospects()}
  end

  def handle_event("mark_replied", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_prospect!() |> Outreach.mark_replied()

    {:noreply,
     socket
     |> put_flash(:info, "Marked as replied. Their campaigns have stopped.")
     |> load_prospects()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_prospect!() |> Outreach.delete_prospect()
    {:noreply, socket |> put_flash(:info, "Prospect deleted.") |> load_prospects()}
  end

  defp save(socket, :new, params) do
    case Outreach.create_prospect(params) do
      {:ok, _prospect} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prospect added.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/prospects")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save(socket, :edit, params) do
    case Outreach.update_prospect(socket.assigns.prospect, params) do
      {:ok, _prospect} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prospect updated.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/prospects")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="flex flex-col sm:flex-row gap-3 sm:items-end justify-between mb-4">
      <form id="prospect-filters" phx-change="filter" class="flex gap-2 flex-1 max-w-lg">
        <input
          type="search"
          name="search"
          value={@search}
          placeholder="Search name, email or company…"
          class="input input-sm flex-1"
          phx-debounce="300"
        />
        <select name="status" class="select select-sm">
          <option value="all" selected={@status == "all"}>All statuses</option>
          <option :for={s <- Prospect.statuses()} value={s} selected={@status == s}>
            {String.capitalize(s)} ({Map.get(@counts, s, 0)})
          </option>
        </select>
      </form>

      <div class="flex gap-2">
        <.link
          navigate={~p"/admin/p/#{@project_id}/prospects/import"}
          class="btn btn-sm"
        >
          <.icon name="hero-arrow-up-tray" class="size-4" /> Import CSV
        </.link>
        <.link
          navigate={~p"/admin/p/#{@project_id}/prospects/new"}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus" class="size-4" /> Add prospect
        </.link>
      </div>
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Company</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@prospects == []}>
              <td colspan="4" class="text-center text-base-content/50 py-8">
                No prospects match.
              </td>
            </tr>
            <tr :for={p <- @prospects}>
              <td>
                <.link
                  navigate={~p"/admin/p/#{@project_id}/prospects/#{p.id}/edit"}
                  class="font-medium hover:text-primary"
                >
                  {Prospect.display_name(p)}
                </.link>
                <div class="text-xs text-base-content/50">{p.email}</div>
              </td>
              <td class="text-sm">
                <div>{p.company}</div>
                <div class="text-xs text-base-content/50">{p.title}</div>
              </td>
              <td><.status_badge status={p.status} /></td>
              <td class="text-right whitespace-nowrap">
                <button
                  :if={Prospect.mailable?(p)}
                  phx-click="mark_replied"
                  phx-value-id={p.id}
                  class="btn btn-xs btn-ghost"
                  title="Stop their campaigns — they got back to you"
                >
                  Replied
                </button>
                <button
                  :if={Prospect.mailable?(p)}
                  phx-click="unsubscribe"
                  phx-value-id={p.id}
                  data-confirm="Unsubscribe and add to the global do-not-contact list?"
                  class="btn btn-xs btn-ghost text-error"
                >
                  Unsubscribe
                </button>
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
    <div class="grid gap-4 lg:grid-cols-3">
      <div class="card bg-base-100 shadow-sm lg:col-span-2">
        <div class="card-body">
          <.form
            id="prospect-form"
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@form[:first_name]} label="First name" />
              <.input field={@form[:last_name]} label="Last name" />
            </div>

            <.input field={@form[:email]} label="Email" />

            <div class="grid gap-4 sm:grid-cols-3">
              <.input field={@form[:company]} label="Company" />
              <.input field={@form[:title]} label="Title" />
              <.input field={@form[:industry]} label="Industry" placeholder="roofing" />
            </div>

            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@form[:phone]} label="Phone" />
              <.input field={@form[:website]} label="Website" />
            </div>

            <.input field={@form[:source]} label="Source" placeholder="Where this lead came from" />
            <.input type="textarea" field={@form[:notes]} label="Notes" />

            <%!-- Anything a CSV carried that had no column of its own. Editable
            as one-per-line `key: value` because that is how few of them there
            usually are — a repeating field group would be more machinery than
            the data deserves. --%>
            <div>
              <label class="text-sm font-medium">Extra fields</label>
              <textarea
                name="prospect[custom_fields_text]"
                rows="3"
                placeholder="crew_size: 6"
                class="textarea w-full mt-1 font-mono text-sm"
              >{custom_fields_text(@form)}</textarea>
              <p class="text-xs text-base-content/50 mt-1">
                One per line, <code>name: value</code>. Each becomes a merge tag —
                <code>crew_size</code>
                is <code>{"{{crew_size}}"}</code>
                in an email.
              </p>
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={~p"/admin/p/#{@project_id}/prospects"} class="btn btn-ghost">
                Cancel
              </.link>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
                Save
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div :if={@live_action == :edit} class="space-y-4">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Merge tags</h2>
            <p class="text-xs text-base-content/50">
              What an email to this person resolves to. A blank one falls back to
              the project's value, then to whatever you write after the pipe — <code class="text-primary">{"{{industry|contractors}}"}</code>.
            </p>

            <dl class="mt-2 space-y-1 text-sm">
              <div
                :for={{name, value} <- Prospect.merge_values(@prospect)}
                class="flex items-baseline justify-between gap-3"
              >
                <dt class="font-mono text-xs text-primary shrink-0">{"{{#{name}}}"}</dt>
                <dd class={[
                  "truncate text-right",
                  if(value in [nil, ""], do: "text-base-content/30", else: "text-base-content/80")
                ]}>
                  {if value in [nil, ""], do: "— not set —", else: value}
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm h-fit">
          <div class="card-body">
            <h2 class="card-title text-base">Mail history</h2>
            <p :if={@messages == []} class="text-sm text-base-content/50">
              Nothing sent yet.
            </p>
            <ul class="space-y-3">
              <li :for={m <- @messages} class="text-sm border-b border-base-200 pb-3 last:border-0">
                <div class="font-medium truncate">{m.subject}</div>
                <div class="text-xs text-base-content/50 flex items-center gap-2 mt-0.5">
                  <.status_badge status={m.status} />
                  <span :if={m.sent_at}>{Calendar.strftime(m.sent_at, "%b %-d")}</span>
                  <span :if={m.open_count > 0}>· {m.open_count} opens</span>
                  <span :if={clicks(m) > 0} class="text-primary">· {clicks(m)} clicks</span>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The map once saved, the raw string mid-edit — the textarea renders both.
  defp custom_fields_text(form) do
    case form[:custom_fields_text].value do
      text when is_binary(text) ->
        text

      _ ->
        case form[:custom_fields].value do
          fields when is_map(fields) ->
            fields |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

          _ ->
            ""
        end
    end
  end

  defp clicks(message), do: Enum.sum(Enum.map(message.tracked_links, & &1.click_count))

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", badge_class(@status)]}>{@status}</span>
    """
  end

  defp badge_class("new"), do: "badge-ghost"
  defp badge_class("active"), do: "badge-info"
  defp badge_class("sent"), do: "badge-info"
  defp badge_class("replied"), do: "badge-success"
  defp badge_class("completed"), do: "badge-ghost"
  defp badge_class("bounced"), do: "badge-error"
  defp badge_class("failed"), do: "badge-error"
  defp badge_class("unsubscribed"), do: "badge-warning"
  defp badge_class(_), do: "badge-ghost"
end
