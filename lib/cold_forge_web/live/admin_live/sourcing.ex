defmodule ColdForgeWeb.AdminLive.Sourcing do
  @moduledoc """
  Saved searches, and what each one turned up.

  A source is made the way a project is: name it after what you are selling,
  point it at the project its prospects belong to, give it the trades and the
  towns, and run it. The project is decided here, once, rather than row by row
  at promotion time — you know which project a search is for when you set it
  up, and being asked again three hundred rows later is only a chance to get
  it wrong.

  The results list is a review queue because the crawler is good at reading a
  page and bad at judging whether an organisation is worth writing to. A
  glazier is not a roofing prospect however cleanly its address parsed.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Source

  @statuses ~w(fetched discovered needs_website rejected promoted)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :statuses, @statuses)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sourcing")
    |> assign(:page_subtitle, "Saved searches. One per thing you're selling.")
    |> assign(:breadcrumbs, [])
    |> assign(:source, nil)
    |> assign(:sources, Sourcing.list_sources())
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New source")
    |> assign(:page_subtitle, nil)
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/sourcing"}])
    |> assign(:source, %Source{})
    |> assign(:projects, Outreach.list_projects())
    |> assign_form(Sourcing.change_source(%Source{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sourcing.get_source!(id)

    socket
    |> assign(:page_title, source.name)
    |> assign(:page_subtitle, "What it looks for, and where.")
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/sourcing"}])
    |> assign(:source, source)
    |> assign(:projects, Outreach.list_projects())
    |> assign_form(
      Sourcing.change_source(source, %{
        segments_text: Source.segments_text(source),
        localities_text: Source.localities_text(source)
      })
    )
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    source = Sourcing.get_source!(id)

    socket
    |> assign(:page_title, source.name)
    |> assign(
      :page_subtitle,
      "Looking for #{segments_sentence(source)} in #{places_sentence(source)}."
    )
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/sourcing"}])
    |> assign(:source, source)
    |> assign(:status, "fetched")
    |> load_results()
  end

  defp load_results(socket) do
    source = socket.assigns.source

    socket
    |> assign(:orgs, Sourcing.list_orgs(source_id: source.id, status: socket.assigns.status))
    |> assign(:counts, Sourcing.counts_for_source(source))
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset))

  ## Events

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      socket.assigns.source
      |> Sourcing.change_source(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"source" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("run", %{"id" => id}, socket) do
    source = Sourcing.get_source!(id)

    case Sourcing.run_source(source) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Searching #{places_sentence(source)}. Results appear as they land.")
         |> push_patch(to: ~p"/admin/sourcing/#{source.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't start that search.")}
    end
  end

  def handle_event("status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status, status) |> load_results()}
  end

  def handle_event("promote", %{"org_id" => id}, socket) do
    org = Sourcing.get_org!(id)
    source = socket.assigns.source

    case Sourcing.promote(org, source.project_id) do
      {:ok, {prospect, _org}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{prospect.company} added to #{source.project.name}.")
         |> load_results()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't add that one: #{describe(reason)}")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    {:ok, _} = id |> Sourcing.get_org!() |> Sourcing.reject(:out_of_segment)
    {:noreply, socket |> put_flash(:info, "Left off the list.") |> load_results()}
  end

  def handle_event("recrawl", %{"id" => id}, socket) do
    org = Sourcing.get_org!(id)
    Sourcing.enqueue_crawls([org])
    {:noreply, put_flash(socket, :info, "Queued another look at #{org.name}.")}
  end

  defp save(socket, :new, params) do
    case Sourcing.create_source(params) do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{source.name} is ready. Run it when you are.")
         |> push_navigate(to: ~p"/admin/sourcing/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save(socket, :edit, params) do
    case Sourcing.update_source(socket.assigns.source, params) do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: ~p"/admin/sourcing/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp describe(other), do: inspect(other)

  ## Render

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div class="flex justify-end mb-4">
      <.link navigate={~p"/admin/sourcing/new"} class="btn btn-primary btn-sm">
        New source
      </.link>
    </div>

    <p :if={@sources == []} class="text-sm opacity-70 py-10 text-center">
      No searches yet. A source is a thing you're selling, a project to put the prospects in,
      and the trades and towns to look in.
    </p>

    <div class="grid gap-3">
      <.link
        :for={source <- @sources}
        navigate={~p"/admin/sourcing/#{source.id}"}
        class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
      >
        <div class="card-body gap-1">
          <div class="flex items-center gap-2">
            <h3 class="font-semibold flex-1">{source.name}</h3>
            <span :if={!source.active} class="badge badge-ghost badge-sm">paused</span>
          </div>
          <p class="text-xs opacity-70">
            {segments_sentence(source)} · {places_sentence(source)} · into {source.project.name}
          </p>
          <p class="text-xs opacity-50">
            {if source.last_run_at,
              do: "last run #{Calendar.strftime(source.last_run_at, "%b %-d at %-I:%M %p")}",
              else: "never run"}
          </p>
        </div>
      </.link>
    </div>
    """
  end

  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <.form for={@form} id="source-form" phx-change="validate" phx-submit="save" class="grid gap-4">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="ExteriorPro — West Michigan"
          />

          <.input
            field={@form[:project_id]}
            type="select"
            label="Prospects go into"
            prompt="Pick a project"
            options={Enum.map(@projects, &{&1.name, &1.id})}
          />

          <.input
            field={@form[:provider]}
            type="select"
            label="Search with"
            options={[
              {"Google Places — the widest coverage, and the only one that returns websites",
               "places"},
              {"OpenStreetMap — free, but thin", "overpass"}
            ]}
          />

          <.input
            field={@form[:segments_text]}
            label="Looking for"
            placeholder="Roofing, siding, gutters, windows"
          />
          <p class="text-xs opacity-60 -mt-3">
            Separate them with commas. This provider knows: {Enum.map_join(
              Source.segments_for(@form[:provider].value || "places"),
              ", ",
              &humanize/1
            )}.
          </p>

          <.input
            field={@form[:localities_text]}
            type="textarea"
            label="Where"
            rows="6"
            placeholder={Source.locality_example(@form[:provider].value || "places")}
          />
          <p class="text-xs opacity-60 -mt-3">
            {Source.locality_hint(@form[:provider].value || "places")}. Places caps a search at
            60 results, so several towns beats one big area.
          </p>

          <.input field={@form[:notes]} type="textarea" label="Notes" rows="2" />
          <.input field={@form[:active]} type="checkbox" label="Active" />
        </div>
      </div>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary">Save</button>
        <.link navigate={~p"/admin/sourcing"} class="btn btn-ghost">Cancel</.link>
      </div>
    </.form>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm mb-4">
      <div class="card-body gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <div class="flex-1 min-w-0">
            <p class="text-sm">
              Prospects go into
              <.link navigate={~p"/admin/p/#{@source.project_id}"} class="link link-primary">
                {@source.project.name}
              </.link>
            </p>
            <p class="text-xs opacity-60">
              {if @source.last_run_at,
                do: "Last run #{Calendar.strftime(@source.last_run_at, "%b %-d at %-I:%M %p")}",
                else: "Never run"}
            </p>
          </div>

          <.link navigate={~p"/admin/sourcing/#{@source.id}/edit"} class="btn btn-sm btn-ghost">
            Edit
          </.link>
          <button
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="run"
            phx-value-id={@source.id}
          >
            Run search
          </button>
        </div>
      </div>
    </div>

    <div role="tablist" class="tabs tabs-box mb-4">
      <button
        :for={status <- @statuses}
        type="button"
        role="tab"
        class={["tab", @status == status && "tab-active"]}
        phx-click="status"
        phx-value-status={status}
      >
        {label_for(status)}
        <span class="badge badge-sm ml-1">{Map.get(@counts, status, 0)}</span>
      </button>
    </div>

    <p :if={@orgs == []} class="text-sm opacity-70 py-8 text-center">
      Nothing at this status{if @source.last_run_at, do: ".", else: " — run the search."}
    </p>

    <div class="grid gap-3">
      <div :for={org <- @orgs} class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-start gap-2">
            <div class="flex-1 min-w-0">
              <h3 class="font-semibold truncate">{org.name}</h3>
              <p class="text-xs opacity-70">
                {humanize(org.segment)}
                <span :if={org.city}>· {org.city}{if org.region, do: ", #{org.region}"}</span>
                · via {org.provider}
              </p>
            </div>
            <span :if={org.fetched_at} class="text-xs opacity-60 whitespace-nowrap">
              looked {Calendar.strftime(org.fetched_at, "%b %-d")}
            </span>
          </div>

          <%!-- The evidence: the address, how it was published, and one click
                to the page it was on. --%>
          <div :if={org.email} class="text-sm">
            <span class="font-mono">{org.email}</span>
            <span class="opacity-60">· published as {org.email_presentation}</span>
            <.link
              :if={org.email_source_url}
              href={org.email_source_url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-primary ml-1"
            >
              see the page
            </.link>
          </div>

          <div :if={org.no_solicitation} class="alert alert-warning text-sm py-2">
            <.icon name="hero-exclamation-triangle" class="size-4" />
            <span>
              This page asks not to be solicited, so the address isn't usable.
              <span :if={org.notice_text} class="opacity-80">“{org.notice_text}”</span>
            </span>
          </div>

          <div class="text-xs opacity-70 flex flex-wrap gap-x-3">
            <span :if={org.website}>
              <.link href={org.website} target="_blank" rel="noopener noreferrer" class="link">
                {pretty_host(org.website)}
              </.link>
            </span>
            <span :if={org.phone}>{org.phone}</span>
            <span :if={org.has_contact_form}>contact form, no address</span>
            <span :if={org.reject_reason}>reason: {humanize(org.reject_reason)}</span>
          </div>

          <div :if={org.status != "promoted"} class="flex flex-wrap gap-2 items-center">
            <button
              :if={(org.email || org.phone) && !org.no_solicitation}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="promote"
              phx-value-org_id={org.id}
            >
              {if org.email, do: "Add to #{@source.project.name}", else: "Add to call list"}
            </button>

            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="recrawl"
              phx-value-id={org.id}
            >
              Look again
            </button>

            <button
              :if={org.status != "rejected"}
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="reject"
              phx-value-id={org.id}
              data-confirm={"Leave #{org.name} off the list?"}
            >
              Not a fit
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Wording

  defp label_for("fetched"), do: "Found an address"
  defp label_for("discovered"), do: "Waiting to crawl"
  defp label_for("needs_website"), do: "No website yet"
  defp label_for("rejected"), do: "Left off"
  defp label_for("promoted"), do: "Prospects"
  defp label_for(other), do: humanize(other)

  defp humanize(nil), do: ""

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp segments_sentence(%Source{segments: []}), do: "nothing yet"

  defp segments_sentence(%Source{segments: segments}),
    do: segments |> Enum.map(&humanize/1) |> to_sentence()

  defp places_sentence(%Source{localities: []}), do: "nowhere yet"
  defp places_sentence(%Source{localities: [one]}), do: one

  defp places_sentence(%Source{localities: localities}),
    do: "#{length(localities)} places"

  defp to_sentence([one]), do: one
  defp to_sentence([a, b]), do: "#{a} and #{b}"

  defp to_sentence(list) do
    {init, [last]} = Enum.split(list, -1)
    "#{Enum.join(init, ", ")} and #{last}"
  end

  defp pretty_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> url
    end
  end
end
