defmodule ColdForgeWeb.AdminLive.Postcards do
  @moduledoc """
  Postcards mailed to prospects: who gets one, what the back says, and which
  ones got scanned.

  Recipients are picked by trade, by whether email can reach them, and by town,
  then added in a batch — a first test is a hundred or so cards, not the whole
  list. Each card gets its own QR, so a scan names the prospect to call.

  The front and the landing page come from the flyer; only the note on the back
  is written here.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.{Flyers, Outreach, Postcards}
  alias ColdForge.Flyers.Content
  alias ColdForge.Postcards.Postcard

  @shown 60
  @per_page 50

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, "Postcards")
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
     |> assign(:tick_ids, MapSet.new())
     |> assign(:page, 1)
     |> assign(:filters, %{trade: "all", reach: "phone", city: "", limit: ""})
     |> assign(:trades, Outreach.list_trades(project_id))
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp load(socket) do
    project = Outreach.get_project!(socket.assigns.project_id)
    content = Flyers.content(project)

    socket
    |> assign(:project, project)
    |> assign(:content, content)
    |> assign(:note_form, note_form(content))
    |> assign(:cards, Postcards.list_postcards(project.id))
    |> clamp_page()
    |> load_matches()
  end

  # After a delete the last page can empty out; land on the one before it.
  defp clamp_page(socket) do
    assign(socket, :page, socket.assigns.page |> min(pages(socket.assigns.cards)) |> max(1))
  end

  defp pages(cards), do: max(1, ceil(length(cards) / @per_page))

  defp load_matches(socket) do
    assign(
      socket,
      :matches,
      Postcards.candidates(socket.assigns.project_id, socket.assigns.filters)
    )
  end

  defp note_form(%Content{} = content) do
    to_form(%{"postcard_note" => content.postcard_note || Content.default_postcard_note()},
      as: :postcard
    )
  end

  ## Events — who gets one

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      trade: params["trade"] || "all",
      reach: params["reach"] || "all",
      city: String.trim(params["city"] || ""),
      limit: String.trim(params["limit"] || "")
    }

    {:noreply, socket |> assign(:filters, filters) |> load_matches()}
  end

  def handle_event("add_cards", _params, socket) do
    pairs =
      case Integer.parse(socket.assigns.filters.limit) do
        {n, _} when n > 0 -> Enum.take(socket.assigns.matches, n)
        _ -> socket.assigns.matches
      end

    added = Postcards.add_cards(socket.assigns.project, pairs)

    {:noreply,
     socket
     |> put_flash(:info, "Added #{count(added, "postcard", "postcards")}.")
     |> load()}
  end

  ## Events — the cards

  def handle_event("page", %{"to" => to}, socket) do
    page =
      case to do
        "next" -> socket.assigns.page + 1
        "prev" -> socket.assigns.page - 1
        n -> String.to_integer(n)
      end

    {:noreply, socket |> assign(:page, page) |> clamp_page()}
  end

  def handle_event("toggle", %{"id" => id}, socket),
    do: {:noreply, update(socket, :tick_ids, &toggle(&1, id))}

  def handle_event("tick_planned", _params, socket) do
    ids = for c <- socket.assigns.cards, c.status == "planned", into: MapSet.new(), do: c.id
    {:noreply, assign(socket, :tick_ids, ids)}
  end

  def handle_event("tick_page", _params, socket) do
    ids = socket.assigns.cards |> page_of(socket.assigns.page) |> Enum.map(& &1.id)
    {:noreply, update(socket, :tick_ids, &MapSet.union(&1, MapSet.new(ids)))}
  end

  def handle_event("tick_none", _params, socket),
    do: {:noreply, assign(socket, :tick_ids, MapSet.new())}

  def handle_event("mark_mailed", _params, socket) do
    n = Postcards.mark_mailed(socket.assigns.project_id, MapSet.to_list(socket.assigns.tick_ids))

    {:noreply,
     socket
     |> assign(:tick_ids, MapSet.new())
     |> put_flash(:info, "Marked #{count(n, "postcard", "postcards")} mailed.")
     |> load()}
  end

  def handle_event("set_status", %{"card_id" => id, "status" => status}, socket) do
    {:ok, _} = id |> Postcards.get_postcard!() |> Postcards.set_status(status)
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case id |> Postcards.get_postcard!() |> Postcards.delete_postcard() do
      {:ok, _} ->
        {:noreply, socket |> update(:tick_ids, &MapSet.delete(&1, id)) |> load()}

      {:error, :mailed} ->
        {:noreply,
         put_flash(socket, :error, "That card's been mailed, so its QR has to keep working.")}
    end
  end

  ## Events — the back of the card

  def handle_event("save_note", %{"postcard" => %{"postcard_note" => note}}, socket) do
    case Flyers.update_content(socket.assigns.project, %{"postcard_note" => note}) do
      {:ok, _project} ->
        {:noreply, socket |> put_flash(:info, "Note saved.") |> load()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Write the flyer first — the card uses its landing page.")}
    end
  end

  defp toggle(set, id),
    do: if(MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id))

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:shown, Enum.take(assigns.matches, @shown))
      |> assign(:to_add, to_add(assigns.matches, assigns.filters.limit))
      |> assign(:ticked, Enum.join(assigns.tick_ids, ","))
      |> assign(:page_cards, page_of(assigns.cards, assigns.page))
      |> assign(:pages, pages(assigns.cards))
      |> assign(:per_page, @per_page)

    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="grid gap-4">
      <div :if={is_nil(@content.headline)} class="alert alert-info text-sm">
        <.icon name="hero-information-circle" class="size-5 shrink-0" />
        <span>
          The postcard's front and landing page come from the flyer.
          <.link navigate={~p"/admin/p/#{@project_id}/flyers"} class="link">Write the flyer</.link>
          first.
        </span>
      </div>

      <%!-- The cards, and what each has produced --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-center gap-2 sticky top-0 z-10 -mx-2 px-2 py-2 bg-base-100">
            <h2 class="card-title text-base flex-1">
              Postcards
              <span :if={@cards != []} class="text-sm font-normal opacity-60">
                {summary(@cards)}
              </span>
            </h2>
            <button
              :if={@pages > 1}
              type="button"
              id="tick-page"
              class="btn btn-xs btn-ghost"
              phx-click="tick_page"
            >
              Tick this page
            </button>
            <button
              :if={Enum.any?(@cards, &(&1.status == "planned"))}
              type="button"
              id="tick-planned"
              class="btn btn-xs btn-ghost"
              phx-click="tick_planned"
            >
              Tick all unmailed
            </button>
            <button
              :if={MapSet.size(@tick_ids) > 0}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="tick_none"
            >
              None
            </button>
            <%= if MapSet.size(@tick_ids) > 0 and @content.headline do %>
              <.link
                id="print-cards"
                href={~p"/admin/p/#{@project_id}/postcards/print?#{[ids: @ticked]}"}
                target="_blank"
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-printer" class="size-4" />
                Print {count(MapSet.size(@tick_ids), "card", "cards")}
              </.link>
              <.link
                id="export-cards"
                href={~p"/admin/p/#{@project_id}/postcards/export?#{[ids: @ticked]}"}
                class="btn btn-sm"
                title="Name, address and QR link per card, for a mailing service"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Mailing list
              </.link>
              <button
                type="button"
                id="mark-mailed"
                class="btn btn-sm"
                phx-click="mark_mailed"
                data-confirm="Mark these cards as mailed today?"
              >
                <.icon name="hero-check" class="size-4" /> Mark mailed
              </button>
            <% end %>
          </div>

          <p :if={@cards == []} class="text-sm opacity-60">
            No postcards yet. Pick who gets one below.
          </p>

          <div :if={@cards != []} class="overflow-x-auto">
            <table class="table table-sm" id="postcards">
              <thead>
                <tr>
                  <th class="w-8"></th>
                  <th>To</th>
                  <th>Status</th>
                  <th class="text-right">Scans</th>
                  <th class="w-8"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- @page_cards} id={"card-#{c.id}"}>
                  <td>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      checked={MapSet.member?(@tick_ids, c.id)}
                      phx-click="toggle"
                      phx-value-id={c.id}
                      aria-label={"Select the card to #{c.name}"}
                    />
                  </td>
                  <td>
                    <span class="font-medium">{c.name}</span>
                    <div class="text-xs opacity-60">
                      {c.street}, {Postcard.city_line(c)}
                      <span :if={c.trade}>· {c.trade}</span>
                    </div>
                  </td>
                  <td>
                    <form phx-change="set_status" id={"status-#{c.id}"}>
                      <input type="hidden" name="card_id" value={c.id} />
                      <select name="status" class="select select-xs" aria-label="Status">
                        {Phoenix.HTML.Form.options_for_select(
                          Enum.map(Postcard.statuses(), &{status_label(&1), &1}),
                          c.status
                        )}
                      </select>
                    </form>
                    <div :if={c.mailed_at} class="text-xs opacity-50">
                      {Calendar.strftime(c.mailed_at, "%b %-d")}
                    </div>
                  </td>
                  <td class="text-right whitespace-nowrap">
                    <span class={["font-semibold", c.scans_count == 0 && "opacity-40"]}>
                      {c.scans_count}
                    </span>
                    <div :if={c.last_scanned_at} class="text-xs opacity-50">
                      last {Calendar.strftime(c.last_scanned_at, "%b %-d")}
                    </div>
                  </td>
                  <td class="whitespace-nowrap">
                    <.link
                      :if={@content.headline}
                      id={"preview-#{c.id}"}
                      href={~p"/admin/p/#{@project_id}/postcards/print?#{[ids: c.id, preview: 1]}"}
                      target="_blank"
                      class="btn btn-xs btn-ghost"
                      title={"Preview the card to #{c.name}"}
                    >
                      <.icon name="hero-eye" class="size-4" /> Preview
                    </.link>
                    <button
                      :if={c.status == "planned" and c.scans_count == 0}
                      type="button"
                      class="btn btn-xs btn-ghost text-error"
                      phx-click="delete"
                      phx-value-id={c.id}
                      data-confirm={"Remove the card to #{c.name}?"}
                      aria-label={"Remove the card to #{c.name}"}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Ticks are kept across pages, so a batch can span several. --%>
          <div :if={@pages > 1} id="postcards-pages">
            <.pagination page={@page} pages={@pages} total={length(@cards)} per_page={@per_page} />
          </div>

          <p :if={@cards != [] and @content.headline} class="text-xs opacity-60">
            A mailing service needs the
            <.link
              href={
                ~p"/admin/p/#{@project_id}/postcards/print?#{[ids: hd(@cards).id, side: "front"]}"
              }
              target="_blank"
              class="link"
            >front once</.link>
            and the backs per card — or print both from <b>Print</b>
            and upload the PDF.
          </p>
        </div>
      </div>

      <%!-- Who gets one --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">Add postcards</h2>
          <p class="text-xs opacity-60 -mt-1">
            Prospects with a street address from a sourcing search. Anyone who unsubscribed,
            has replied, or already has a card is left out, and each company address gets one card.
          </p>

          <.form for={%{}} as={:filters} id="card-filters" phx-change="filter" class="grid gap-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                type="choice"
                id="filter-reach"
                name="filters[reach]"
                value={@filters.reach}
                label="Who"
                options={[
                  {"Phone only — email can't reach them", "phone"},
                  {"Being emailed", "email"},
                  {"Everyone", "all"}
                ]}
              />
              <.input
                type="choice"
                id="filter-trade"
                name="filters[trade]"
                value={@filters.trade}
                label="Trade"
                options={[{"All trades", "all"} | Enum.map(@trades, &{&1.label, &1.key})]}
              />
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                type="text"
                id="filter-city"
                name="filters[city]"
                value={@filters.city}
                label="Town (optional)"
                placeholder="Grand Rapids"
                phx-debounce="300"
              />
              <.input
                type="number"
                id="filter-limit"
                name="filters[limit]"
                value={@filters.limit}
                label="How many (blank for all)"
                min="1"
                placeholder="150"
                phx-debounce="300"
              />
            </div>
          </.form>

          <p class="text-sm" id="match-count">
            <b>{length(@matches)}</b> {if length(@matches) == 1,
              do: "prospect matches",
              else: "prospects match"}
          </p>

          <div
            :if={@shown != []}
            class="max-h-64 overflow-y-auto grid gap-x-4 gap-y-1 sm:grid-cols-2 pr-1"
          >
            <div :for={{p, o} <- @shown} class="text-sm min-w-0">
              <span class="block truncate">{p.company || o.name}</span>
              <span class="block truncate text-xs opacity-50">{o.street}, {o.city}</span>
            </div>
          </div>
          <p :if={length(@matches) > @shown} class="text-xs opacity-50">
            Showing the first {@shown}.
          </p>

          <button
            type="button"
            id="add-cards"
            class="btn btn-sm self-start"
            phx-click="add_cards"
            disabled={@to_add == 0}
          >
            Add {count(@to_add, "postcard", "postcards")}
          </button>
        </div>
      </div>

      <%!-- The back of the card --%>
      <.form
        for={@note_form}
        id="note-form"
        phx-submit="save_note"
        class="card bg-base-100 shadow-sm"
      >
        <div class="card-body gap-2">
          <h2 class="card-title text-base">The back of the card</h2>
          <p class="text-xs opacity-60 -mt-1">
            Printed beside the QR. Blank lines between paragraphs; the first prints bold.
            <code>{"{{company}}"}</code>
            is the company it's going to. The front is the flyer's photo, headline and highlights.
          </p>
          <.input field={@note_form[:postcard_note]} type="textarea" rows="8" />
          <div>
            <button type="submit" class="btn btn-primary" disabled={is_nil(@content.headline)}>
              Save
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp page_of(cards, page),
    do: cards |> Enum.drop((page - 1) * @per_page) |> Enum.take(@per_page)

  defp to_add(matches, limit) do
    case Integer.parse(limit || "") do
      {n, _} when n > 0 -> min(n, length(matches))
      _ -> length(matches)
    end
  end

  defp summary(cards) do
    mailed = Enum.count(cards, &(&1.status == "mailed"))
    scanned = Enum.count(cards, &(&1.scans_count > 0))
    "#{length(cards)} · #{mailed} mailed · #{scanned} scanned"
  end

  defp status_label("planned"), do: "Not mailed"
  defp status_label("mailed"), do: "Mailed"
  defp status_label("returned"), do: "Returned"

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{n} #{plural}"
end
