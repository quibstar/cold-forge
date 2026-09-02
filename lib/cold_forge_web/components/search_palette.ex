defmodule ColdForgeWeb.SearchPalette do
  @moduledoc """
  A ⌘K / Ctrl-K command palette: find a prospect, sequence or project from
  anywhere and jump straight to it.

  Search is deliberately *not* scoped to the project you're currently looking
  at. You remember the person's name, not which idea you filed them under — so
  a palette that only searched the current project would miss the thing you're
  actually after.

  Rendered once by `Layouts.admin`; opening is server-owned so the header
  button and the keyboard shortcut go through the same path.
  """
  use ColdForgeWeb, :live_component

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect

  # "All" searches every entity at once; the rest narrow to one.
  @entities [
    {:all, "All"},
    {:prospects, "Prospects"},
    {:sequences, "Sequences"},
    {:projects, "Projects"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:q, "")
     |> assign(:entity, :all)
     |> assign(:entities, @entities)
     |> assign(:results, [])}
  end

  @impl true
  def update(assigns, socket) do
    # A custom update/2 must merge assigns in explicitly, or `id` is dropped.
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, socket |> assign(:open, true) |> run_search()}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:q, q) |> run_search()}
  end

  def handle_event("set_entity", %{"entity" => entity}, socket) do
    {:noreply, socket |> assign(:entity, String.to_existing_atom(entity)) |> run_search()}
  end

  defp run_search(socket) do
    assign(socket, :results, search(socket.assigns.entity, socket.assigns.q))
  end

  defp search(_entity, q) when q in [nil, ""], do: []

  # "All" runs every entity shallowly; a specific entity goes deeper.
  defp search(:all, q) do
    for {key, label} <- @entities,
        key != :all,
        items = items_for(key, q, 4),
        items != [] do
      %{label: label, items: items}
    end
  end

  defp search(entity, q) do
    case items_for(entity, q, 10) do
      [] -> []
      items -> [%{label: entity_label(entity), items: items}]
    end
  end

  defp items_for(:prospects, q, limit) do
    q
    |> Outreach.search_prospects(limit)
    |> Enum.map(
      &%{
        title: Prospect.display_name(&1),
        subtitle: subtitle_for(&1),
        path: ~p"/admin/p/#{&1.project_id}/prospects/#{&1.id}/edit"
      }
    )
  end

  defp items_for(:sequences, q, limit) do
    q
    |> Outreach.search_sequences(limit)
    |> Enum.map(
      &%{
        title: &1.name,
        subtitle: "#{&1.status} sequence",
        path: ~p"/admin/p/#{&1.project_id}/sequences/#{&1.id}"
      }
    )
  end

  defp items_for(:projects, q, limit) do
    q
    |> Outreach.search_projects(limit)
    |> Enum.map(
      &%{
        title: &1.name,
        subtitle: &1.from_email,
        path: ~p"/admin/p/#{&1.id}/prospects"
      }
    )
  end

  defp subtitle_for(%Prospect{} = prospect) do
    [prospect.email, prospect.company]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook=".CmdK">
      <div
        :if={@open}
        class="fixed inset-0 z-[60] flex items-start justify-center p-4 sm:pt-[12vh]"
      >
        <div
          class="absolute inset-0 bg-black/40 backdrop-blur-sm"
          phx-click="close"
          phx-target={@myself}
        />
        <div
          class="relative w-full max-w-xl overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
          phx-window-keydown="close"
          phx-key="Escape"
          phx-target={@myself}
        >
          <form
            id="search-palette-form"
            phx-change="search"
            phx-target={@myself}
            class="flex items-center gap-2 border-b border-base-200 px-4"
          >
            <.icon name="hero-magnifying-glass" class="size-5 shrink-0 text-base-content/40" />
            <input
              id="palette-input"
              name="q"
              value={@q}
              autocomplete="off"
              phx-debounce="150"
              phx-mounted={JS.focus()}
              placeholder={search_placeholder(@entity)}
              class="w-full bg-transparent py-3.5 text-sm outline-none placeholder:text-base-content/40"
            />
            <kbd class="hidden shrink-0 rounded border border-base-300 px-1.5 py-0.5 text-[10px] text-base-content/40 sm:block">
              esc
            </kbd>
          </form>

          <div class="flex items-center gap-1 border-b border-base-200 px-3 py-2">
            <button
              :for={{key, label} <- @entities}
              type="button"
              phx-click="set_entity"
              phx-value-entity={key}
              phx-target={@myself}
              class={[
                "rounded-lg px-2.5 py-1 text-xs font-medium transition-colors",
                if(@entity == key,
                  do: "bg-primary/10 text-primary",
                  else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <div class="max-h-80 overflow-y-auto p-2">
            <p
              :if={@q != "" and @results == []}
              class="px-3 py-8 text-center text-sm text-base-content/50"
            >
              No matches for “{@q}”.
            </p>
            <p :if={@q == ""} class="px-3 py-8 text-center text-sm text-base-content/50">
              Type to search — name, email, company, or sequence.
            </p>
            <div :for={section <- @results} class="mb-1">
              <div class="px-3 pt-2 pb-1 text-[10px] font-semibold uppercase tracking-wide text-base-content/40">
                {section.label}
              </div>
              <.link
                :for={r <- section.items}
                navigate={r.path}
                phx-click="close"
                phx-target={@myself}
                class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 hover:bg-base-200"
              >
                <span class="min-w-0">
                  <span class="block truncate text-sm font-medium text-base-content">
                    {r.title}
                  </span>
                  <span
                    :if={r.subtitle not in [nil, ""]}
                    class="block truncate text-xs text-base-content/50"
                  >
                    {r.subtitle}
                  </span>
                </span>
                <.icon name="hero-arrow-up-right" class="size-4 shrink-0 text-base-content/30" />
              </.link>
            </div>
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CmdK">
        export default {
          mounted() {
            this._onKey = (e) => {
              if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
                e.preventDefault()
                this.pushEventTo(this.el, "open", {})
              }
            }
            document.addEventListener("keydown", this._onKey)
          },
          destroyed() {
            document.removeEventListener("keydown", this._onKey)
          }
        }
      </script>
    </div>
    """
  end

  defp entity_label(entity) do
    {_key, label} = Enum.find(@entities, fn {key, _} -> key == entity end)
    label
  end

  defp search_placeholder(:all), do: "Search everything…"
  defp search_placeholder(entity), do: "Search #{entity_label(entity)}…"
end
