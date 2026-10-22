defmodule ColdForgeWeb.AdminLive.Flyers do
  @moduledoc """
  Printed counter flyers: where they go, what they say, and which ones get
  scanned.

  Places come from a sourcing search ("roofing supply, building supply") or are
  typed in. Each gets its own QR code, so the scan count beside it says which
  counters produced anybody — after a month, the next batch goes there.

  The flyer is the cheap part. Asking the branch manager to put it up is the
  conversation worth having, so each place carries a status and notes for it.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.{Flyers, Outreach, Sourcing}
  alias ColdForge.Flyers.{Content, Placement}

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, socket.assigns.current_project.name)
    |> assign(:print_ids, MapSet.new())
    |> assign(:pick_org_ids, MapSet.new())
    |> assign(:candidate_source_id, nil)
    |> assign(:new_place, to_form(Flyers.change_placement(%Placement{}), as: :place))
    |> load()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    placement = Flyers.get_placement!(id)

    socket
    |> assign(:page_title, placement.venue_name)
    |> assign(:breadcrumbs, [{"Flyers", ~p"/admin/p/#{socket.assigns.project_id}/flyers"}])
    |> assign(:placement, placement)
    |> assign(:place_form, to_form(Flyers.change_placement(placement), as: :place))
  end

  # The project is re-read rather than taken from `current_project`, which was
  # loaded on mount and doesn't see a flyer saved since.
  defp load(socket) do
    project = Outreach.get_project!(socket.assigns.project_id)

    socket
    |> assign(:project, project)
    |> assign(:content, Flyers.content(project))
    |> assign(:content_form, to_form(Flyers.change_content(project), as: :flyer))
    |> assign(:placements, Flyers.list_placements(project.id))
    # Only flyer-location searches: a prospect search is the contractors you're
    # selling to, and none of them belongs on the flyer list.
    |> assign(
      :sources,
      project.id
      |> then(&Sourcing.list_sources(project_id: &1))
      |> Enum.filter(&ColdForge.Sourcing.Source.flyers?/1)
    )
    |> assign(
      :candidates,
      Flyers.candidate_orgs(project.id, socket.assigns[:candidate_source_id])
    )
  end

  ## Events — places

  @impl true
  def handle_event("toggle_print", %{"id" => id}, socket),
    do: {:noreply, update(socket, :print_ids, &toggle(&1, id))}

  def handle_event("print_all", _params, socket) do
    ids =
      socket.assigns.placements
      |> Enum.reject(&(&1.status in ["declined", "removed"]))
      |> MapSet.new(& &1.id)

    {:noreply, assign(socket, :print_ids, ids)}
  end

  def handle_event("print_none", _params, socket),
    do: {:noreply, assign(socket, :print_ids, MapSet.new())}

  def handle_event("set_status", %{"placement_id" => id, "status" => status}, socket) do
    {:ok, _} = id |> Flyers.get_placement!() |> Flyers.update_placement(%{status: status})
    {:noreply, load(socket)}
  end

  def handle_event("pick_source", %{"source_id" => source_id}, socket) do
    source_id = if source_id == "", do: nil, else: source_id

    {:noreply,
     socket
     |> assign(:candidate_source_id, source_id)
     |> assign(:pick_org_ids, MapSet.new())
     |> load()}
  end

  def handle_event("toggle_org", %{"id" => id}, socket),
    do: {:noreply, update(socket, :pick_org_ids, &toggle(&1, id))}

  def handle_event("pick_all_orgs", _params, socket),
    do: {:noreply, assign(socket, :pick_org_ids, MapSet.new(socket.assigns.candidates, & &1.id))}

  def handle_event("add_orgs", _params, socket) do
    added = Flyers.add_orgs(socket.assigns.project, MapSet.to_list(socket.assigns.pick_org_ids))

    {:noreply,
     socket
     |> assign(:pick_org_ids, MapSet.new())
     |> put_flash(:info, "Added #{added} #{if added == 1, do: "place", else: "places"}.")
     |> load()}
  end

  def handle_event("validate_new_place", %{"place" => params}, socket) do
    form =
      %Placement{}
      |> Flyers.change_placement(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :place)

    {:noreply, assign(socket, :new_place, form)}
  end

  def handle_event("add_place", %{"place" => params}, socket) do
    case Flyers.create_placement(socket.assigns.project, params) do
      {:ok, placement} ->
        {:noreply,
         socket
         |> assign(:new_place, to_form(Flyers.change_placement(%Placement{}), as: :place))
         |> put_flash(:info, "Added #{placement.venue_name}.")
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_place, to_form(changeset, as: :place))}
    end
  end

  ## Events — the flyer's words

  def handle_event("validate_content", %{"flyer" => params}, socket) do
    form =
      socket.assigns.project
      |> Flyers.change_content(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :flyer)

    {:noreply, assign(socket, :content_form, form)}
  end

  def handle_event("save_content", %{"flyer" => params}, socket) do
    case Flyers.update_content(socket.assigns.project, params) do
      {:ok, _project} ->
        {:noreply, socket |> put_flash(:info, "Flyer saved.") |> load()}

      {:error, %Ecto.Changeset{changes: %{flyer: content_changeset}}} ->
        {:noreply, assign(socket, :content_form, to_form(content_changeset, as: :flyer))}
    end
  end

  ## Events — one place

  def handle_event("validate_place", %{"place" => params}, socket) do
    form =
      socket.assigns.placement
      |> Flyers.change_placement(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :place)

    {:noreply, assign(socket, :place_form, form)}
  end

  def handle_event("save_place", %{"place" => params}, socket) do
    case Flyers.update_placement(socket.assigns.placement, params) do
      {:ok, _placement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/flyers")}

      {:error, changeset} ->
        {:noreply, assign(socket, :place_form, to_form(changeset, as: :place))}
    end
  end

  def handle_event("delete_place", _params, socket) do
    case Flyers.delete_placement(socket.assigns.placement) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/flyers")}

      {:error, :printed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "It may already be on a board, so its QR has to keep working. Mark it removed instead."
         )}
    end
  end

  defp toggle(set, id),
    do: if(MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id))

  ## Rendering

  @impl true
  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <.form
      for={@place_form}
      id="place-form"
      phx-change="validate_place"
      phx-submit="save_place"
      class="card bg-base-100 shadow-sm"
    >
      <div class="card-body gap-2">
        <p class="text-xs opacity-60">
          Flyer code <code class="font-mono">{@placement.code}</code>
          · {count(@placement.scans_count, "scan", "scans")}
        </p>
        <.input field={@place_form[:venue_name]} label="Place" />
        <.input field={@place_form[:address]} label="Address" />
        <.input field={@place_form[:phone]} label="Phone" />
        <.input
          field={@place_form[:trade]}
          label="Trade (optional)"
          placeholder="roofing"
        />
        <p class="text-xs opacity-60 -mt-2">
          Names the trade at the top of the flyer, and tells the landing page which trade to show.
        </p>
        <.input
          field={@place_form[:status]}
          type="select"
          label="Status"
          options={Enum.map(Placement.statuses(), &{status_label(&1), &1})}
        />
        <.input
          field={@place_form[:notes]}
          type="textarea"
          label="Notes"
          rows="4"
          placeholder="Who you spoke to, what they said, when to go back."
        />
        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">Save</button>
          <.link navigate={~p"/admin/p/#{@project_id}/flyers"} class="btn btn-ghost">Cancel</.link>
          <button
            :if={@placement.status == "planned" and @placement.scans_count == 0}
            type="button"
            phx-click="delete_place"
            data-confirm="Delete this place?"
            class="btn btn-ghost text-error ml-auto"
          >
            Delete
          </button>
        </div>
      </div>
    </.form>
    """
  end

  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="grid gap-4">
      <div :if={is_nil(@content.headline)} class="alert alert-info text-sm">
        <.icon name="hero-information-circle" class="size-5 shrink-0" />
        <span>
          Write what the flyer says first, at the bottom of this page — then add places and print.
        </span>
      </div>

      <%!-- Where flyers go, and what each has produced --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="card-title text-base flex-1">Where flyers go</h2>
            <button
              :if={@placements != []}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="print_all"
            >
              Tick all
            </button>
            <button
              :if={MapSet.size(@print_ids) > 0}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="print_none"
            >
              None
            </button>
            <.link
              :if={MapSet.size(@print_ids) > 0 and @content.headline}
              id="print-flyers"
              href={~p"/admin/p/#{@project_id}/flyers/print?#{[ids: Enum.join(@print_ids, ",")]}"}
              target="_blank"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-printer" class="size-4" />
              Print {count(MapSet.size(@print_ids), "flyer", "flyers")}
            </.link>
          </div>

          <p :if={@placements == []} class="text-sm opacity-60">
            No places yet. Add supply houses below — from a sourcing search, or by hand.
          </p>

          <div :if={@placements != []} class="overflow-x-auto">
            <table class="table table-sm" id="placements">
              <thead>
                <tr>
                  <th class="w-8"></th>
                  <th>Place</th>
                  <th>Status</th>
                  <th class="text-right">Scans</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @placements} id={"placement-#{p.id}"}>
                  <td>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      checked={MapSet.member?(@print_ids, p.id)}
                      phx-click="toggle_print"
                      phx-value-id={p.id}
                      aria-label={"Print a flyer for #{p.venue_name}"}
                    />
                  </td>
                  <td>
                    <.link
                      navigate={~p"/admin/p/#{@project_id}/flyers/#{p.id}/edit"}
                      class="font-medium hover:text-primary"
                    >
                      {p.venue_name}
                    </.link>
                    <div class="text-xs opacity-60">
                      {p.address}
                      <span :if={p.trade}>· {p.trade}</span>
                    </div>
                    <div :if={p.notes not in [nil, ""]} class="text-xs opacity-50 truncate max-w-md">
                      {p.notes}
                    </div>
                  </td>
                  <td>
                    <form phx-change="set_status" id={"status-#{p.id}"}>
                      <input type="hidden" name="placement_id" value={p.id} />
                      <select name="status" class="select select-xs" aria-label="Status">
                        {Phoenix.HTML.Form.options_for_select(
                          Enum.map(Placement.statuses(), &{status_label(&1), &1}),
                          p.status
                        )}
                      </select>
                    </form>
                  </td>
                  <td class="text-right whitespace-nowrap">
                    <span class={["font-semibold", p.scans_count == 0 && "opacity-40"]}>
                      {p.scans_count}
                    </span>
                    <div :if={p.last_scanned_at} class="text-xs opacity-50">
                      last {Calendar.strftime(p.last_scanned_at, "%b %-d")}
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%!-- Adding places --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">Add places</h2>

          <div :if={@sources == []} class="text-sm opacity-60">
            Run a search on the
            <.link navigate={~p"/admin/p/#{@project_id}/sourcing"} class="link">Sourcing</.link>
            tab for <code>roofing supply, building supply, window distributor</code>, with
            "What these are for" set to <b>Flyer locations</b>, then add what it finds here.
          </div>

          <form :if={@sources != []} id="pick-source" phx-change="pick_source">
            <.input
              type="select"
              id="candidate-source"
              name="source_id"
              value={@candidate_source_id}
              label="From a sourcing search"
              prompt="Choose a search"
              options={Enum.map(@sources, &{&1.name, &1.id})}
            />
          </form>

          <p
            :if={@candidate_source_id && @candidates == []}
            class="text-sm opacity-60"
          >
            Everything from that search is already on the list.
          </p>

          <div :if={@candidates != []} class="space-y-2" id="candidates">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <span class="opacity-70">
                {count(length(@candidates), "result", "results")} not on the list yet
              </span>
              <button type="button" class="btn btn-xs btn-ghost" phx-click="pick_all_orgs">
                Tick all
              </button>
            </div>
            <div class="max-h-64 overflow-y-auto grid gap-x-4 gap-y-1 sm:grid-cols-2 pr-1">
              <label :for={org <- @candidates} class="flex items-center gap-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs"
                  checked={MapSet.member?(@pick_org_ids, org.id)}
                  phx-click="toggle_org"
                  phx-value-id={org.id}
                />
                <span class="truncate">{org.name}</span>
                <span class="ml-auto text-xs opacity-50 whitespace-nowrap">{org.city}</span>
              </label>
            </div>
            <button
              type="button"
              id="add-orgs"
              class="btn btn-sm"
              phx-click="add_orgs"
              disabled={MapSet.size(@pick_org_ids) == 0}
            >
              Add {count(MapSet.size(@pick_org_ids), "place", "places")}
            </button>
          </div>

          <.form
            for={@new_place}
            id="new-place-form"
            phx-change="validate_new_place"
            phx-submit="add_place"
            class="grid gap-2 sm:grid-cols-[2fr_2fr_1fr_auto] items-end border-t border-base-300 pt-3"
          >
            <.input field={@new_place[:venue_name]} label="Or by hand" placeholder="ABC Supply" />
            <.input field={@new_place[:address]} placeholder="Wyoming, MI" />
            <.input field={@new_place[:trade]} placeholder="Trade (optional)" />
            <button type="submit" class="btn btn-sm mb-2">Add</button>
          </.form>
        </div>
      </div>

      <%!-- What the flyer says --%>
      <.form
        for={@content_form}
        id="flyer-form"
        phx-change="validate_content"
        phx-submit="save_content"
        class="card bg-base-100 shadow-sm"
      >
        <div class="card-body gap-2">
          <h2 class="card-title text-base">What the flyer says</h2>
          <p class="text-xs opacity-60 -mt-1">
            Keep the headline word for word the same as the page the QR lands on — a scan that
            lands on different words reads as the wrong page.
          </p>

          <.input
            field={@content_form[:url]}
            label="Where a scan lands"
            placeholder="https://exteriorpro.io/pro"
          />
          <div class="grid gap-2 sm:grid-cols-2">
            <.input
              field={@content_form[:eyebrow]}
              label="Above the headline"
              placeholder="For exterior contractors"
            />
            <.input
              field={@content_form[:trade_eyebrow]}
              label="…when a place names a trade"
              placeholder="For {{trade}} contractors"
            />
          </div>
          <.input
            field={@content_form[:headline]}
            type="textarea"
            rows="2"
            label="Headline (a new line breaks it)"
            placeholder="Run the job.\nNot the paperwork."
          />
          <.input field={@content_form[:lede]} type="textarea" rows="2" label="Under the headline" />
          <.input
            field={@content_form[:steps]}
            type="textarea"
            rows="4"
            label="Points, one per line"
            placeholder="Lead comes in — call, web form, or forwarded from Angi"
          />
          <p class="text-xs opacity-60 -mt-2">The part before " — " prints bold.</p>
          <.input field={@content_form[:closing]} label="Closing line" />
          <.input
            field={@content_form[:terms]}
            label="Next to the QR"
            placeholder="Free for 30 days. No credit card."
          />
          <.input field={@content_form[:footer]} label="Footer" />

          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary">Save</button>
            <span :if={@content.url} class="text-xs opacity-60">
              Prints as <span class="font-medium">{Content.display_url(@content)}</span>
            </span>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp status_label("planned"), do: "Planned"
  defp status_label("asked"), do: "Asked"
  defp status_label("posted"), do: "Up"
  defp status_label("declined"), do: "Said no"
  defp status_label("removed"), do: "Taken down"

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{n} #{plural}"
end
