defmodule ColdForgeWeb.AdminLive.Sourcing do
  @moduledoc """
  Saved searches, and what each one turned up.

  A source belongs to the project it fills, so it lives under that project
  rather than in the sidebar: there is no "which project" field because being
  here is the answer. Name it after what you are selling, give it the trades
  and the towns, and run it.

  Promotion asks nothing either. The destination was settled the moment you
  opened this project, and being asked again three hundred rows later is only
  a chance to get it wrong.

  The results list is a review queue because the crawler is good at reading a
  page and bad at judging whether an organisation is worth writing to. A
  glazier is not a roofing prospect however cleanly its address parsed.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Source, Towns}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :views, Sourcing.views())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, %{"project_id" => project_id}) do
    socket
    |> assign(:page_title, "Sourcing")
    |> assign(:page_subtitle, "Saved searches that fill this project.")
    |> assign(:breadcrumbs, [])
    |> assign(:source, nil)
    |> assign(:sources, Sourcing.list_sources(project_id: project_id))
  end

  defp apply_action(socket, :new, %{"project_id" => project_id}) do
    socket
    |> assign(:page_title, "New source")
    |> assign(:page_subtitle, nil)
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/p/#{project_id}/sourcing"}])
    |> assign(:source, %Source{project_id: project_id})
    |> reset_picker()
    |> assign_form(Sourcing.change_source(%Source{project_id: project_id}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sourcing.get_source!(id)

    socket
    |> assign(:page_title, source.name)
    |> assign(:page_subtitle, "What it looks for, and where.")
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/p/#{source.project_id}/sourcing"}])
    |> assign(:source, source)
    |> reset_picker()
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
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/p/#{source.project_id}/sourcing"}])
    |> assign(:source, source)
    |> assign(:plan, Source.plan(source))
    |> assign(:status, "email")
    |> load_results()
  end

  defp load_results(socket) do
    source = socket.assigns.source

    socket
    |> assign(:orgs, Sourcing.list_orgs(source_id: source.id, view: socket.assigns.status))
    |> assign(:counts, Sourcing.counts_by_view(source))
    |> assign(:addable, Sourcing.addable_counts(source))
    |> assign(:progress, Sourcing.progress(source))
    |> schedule_refresh()
  end

  # While a run is going, the page re-reads itself every few seconds so the
  # progress and the tabs move without a reload. It stops once there's
  # nothing left to wait for, and never runs twice at once.
  @refresh_ms 5_000

  defp schedule_refresh(socket) do
    running? = not socket.assigns.progress.done and socket.assigns.source.last_run_at != nil

    if connected?(socket) and running? and not Map.get(socket.assigns, :refresh_scheduled, false) do
      Process.send_after(self(), :refresh, @refresh_ms)
      assign(socket, :refresh_scheduled, true)
    else
      socket
    end
  end

  @impl true
  def handle_info(:refresh, %{assigns: %{live_action: :show}} = socket) do
    source = Sourcing.get_source!(socket.assigns.source.id)

    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:refresh_scheduled, false)
     |> load_results()}
  end

  def handle_info(:refresh, socket), do: {:noreply, assign(socket, :refresh_scheduled, false)}

  # The plan is worked out from whatever has been typed, valid or not, so the
  # cost of a typo or of a whole state is on screen before Save.
  @default_picker %{
    "mode" => "state",
    "state" => "",
    "center" => "",
    "miles" => "50",
    "min_population" => "5000"
  }

  # The town picker's own state. It never saves anything itself: "Add" writes
  # the ticked towns into "Where" as ordinary lines, so what gets searched is
  # always visible and editable there, and a saved search can't quietly change
  # when the population estimates do.
  defp reset_picker(socket) do
    socket
    |> assign(:picker, @default_picker)
    |> assign(:picker_towns, [])
    |> assign(:picker_skipped, MapSet.new())
  end

  defp update_picker(socket, nil), do: socket

  defp update_picker(socket, params) do
    picker = Map.merge(socket.assigns.picker, Map.take(params, Map.keys(@default_picker)))

    # A centre from another state no longer makes sense once the state changes.
    picker =
      if picker["state"] != socket.assigns.picker["state"],
        do: Map.put(picker, "center", ""),
        else: picker

    changed? = picker != socket.assigns.picker

    socket
    |> assign(:picker, picker)
    |> assign(:picker_towns, picker_towns(picker))
    |> then(fn s -> if changed?, do: assign(s, :picker_skipped, MapSet.new()), else: s end)
  end

  defp picker_towns(%{"mode" => "radius", "center" => ""}), do: []

  defp picker_towns(%{"mode" => "radius"} = picker) do
    Towns.near(picker["center"], to_int(picker["miles"]), to_int(picker["min_population"])) || []
  end

  defp picker_towns(%{"state" => ""}), do: []

  defp picker_towns(picker),
    do: Towns.in_state(picker["state"], to_int(picker["min_population"]))

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp picked(towns, skipped), do: Enum.reject(towns, &MapSet.member?(skipped, &1.label))

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset))
    |> assign(:plan, Source.plan(Ecto.Changeset.apply_changes(changeset)))
  end

  ## Events

  @impl true
  def handle_event("validate", params, socket) do
    socket = update_picker(socket, params["picker"])

    case params["source"] do
      nil ->
        {:noreply, socket}

      source_params ->
        changeset =
          socket.assigns.source
          |> Sourcing.change_source(source_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("toggle_town", %{"label" => label}, socket) do
    skipped = socket.assigns.picker_skipped

    skipped =
      if MapSet.member?(skipped, label),
        do: MapSet.delete(skipped, label),
        else: MapSet.put(skipped, label)

    {:noreply, assign(socket, :picker_skipped, skipped)}
  end

  def handle_event("pick_all", _params, socket),
    do: {:noreply, assign(socket, :picker_skipped, MapSet.new())}

  def handle_event("pick_none", _params, socket) do
    labels = MapSet.new(socket.assigns.picker_towns, & &1.label)
    {:noreply, assign(socket, :picker_skipped, labels)}
  end

  # Appends the ticked towns to "Where", skipping any already there, and leaves
  # the rest of the form exactly as typed.
  def handle_event("add_towns", _params, socket) do
    params = socket.assigns.form.params || %{}

    existing =
      (params["localities_text"] || "")
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)

    added =
      socket.assigns.picker_towns
      |> picked(socket.assigns.picker_skipped)
      |> Enum.map(& &1.label)
      |> Enum.reject(&(&1 in existing))

    lines = Enum.reject(existing, &(&1 == "")) ++ added

    changeset =
      Sourcing.change_source(
        socket.assigns.source,
        Map.put(params, "localities_text", Enum.join(lines, "\n"))
      )

    {:noreply,
     socket
     |> assign_form(changeset)
     |> assign(:picker_skipped, MapSet.new())
     |> put_flash(
       :info,
       "Added #{length(added)} #{if length(added) == 1, do: "town", else: "towns"} to Where."
     )}
  end

  def handle_event("save", %{"source" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  def handle_event("queue_missing", _params, socket) do
    queued = Sourcing.queue_missing_crawls(socket.assigns.source)

    {:noreply,
     socket
     |> put_flash(:info, "Queued #{queued} website checks.")
     |> load_results()}
  end

  def handle_event("run", %{"id" => id}, socket) do
    source = Sourcing.get_source!(id)

    case Sourcing.run_source(source) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Searching #{places_sentence(source)}. Results appear as they land.")
         |> push_patch(to: ~p"/admin/p/#{source.project_id}/sourcing/#{source.id}")}

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

  def handle_event("add_all", %{"kind" => kind}, socket) when kind in ["email", "calls"] do
    source = socket.assigns.source
    {:ok, totals} = Sourcing.promote_all(source, String.to_existing_atom(kind))

    {:noreply,
     socket |> put_flash(:info, add_all_message(kind, totals, source)) |> load_results()}
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
    # Taken from the URL rather than the params: a project field on the form
    # would be a second chance to disagree with the page you are standing on.
    params = Map.put(params, "project_id", socket.assigns.source.project_id)

    case Sourcing.create_source(params) do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{source.name} is ready. Run it when you are.")
         |> push_navigate(to: ~p"/admin/p/#{source.project_id}/sourcing/#{source.id}")}

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
         |> push_navigate(to: ~p"/admin/p/#{source.project_id}/sourcing/#{source.id}")}

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
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="flex justify-end mb-4">
      <.link
        navigate={~p"/admin/p/#{@current_project.id}/sourcing/new"}
        class="btn btn-primary btn-sm"
      >
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
        navigate={~p"/admin/p/#{@current_project.id}/sourcing/#{source.id}"}
        class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow"
      >
        <div class="card-body gap-1">
          <div class="flex items-center gap-2">
            <h3 class="font-semibold flex-1">{source.name}</h3>
            <span :if={!source.active} class="badge badge-ghost badge-sm">paused</span>
          </div>
          <p class="text-xs opacity-70">
            {segments_sentence(source)} · {places_sentence(source)}
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
    <.project_tabs project={@current_project} current_path={@current_path} />

    <.form for={@form} id="source-form" phx-change="validate" phx-submit="save" class="grid gap-4">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="ExteriorPro — West Michigan"
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
            placeholder="Roofing, siding, windows & doors, deck builder"
          />
          <p :if={(@form[:provider].value || "places") == "places"} class="text-xs opacity-60 -mt-3">
            Separate trades with commas. Anything works — it's searched as you write it.
            These have tuned searches built in: {Enum.map_join(
              Source.segments_for("places"),
              ", ",
              &humanize/1
            )}. Add other wordings of one trade with <code>|</code>, like <code>deck builder | deck contractor</code>.
          </p>
          <p :if={@form[:provider].value == "overpass"} class="text-xs opacity-60 -mt-3">
            Separate them with commas. OpenStreetMap only knows: {Enum.map_join(
              Source.segments_for("overpass"),
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
            60 results, so a state is searched town by town — every town of 5,000+. For smaller
            towns or a radius, use Add towns below.
          </p>

          <.town_picker
            :if={(@form[:provider].value || "places") == "places"}
            picker={@picker}
            towns={@picker_towns}
            skipped={@picker_skipped}
          />

          <.plan_summary plan={@plan} id="source-plan" />

          <.input field={@form[:notes]} type="textarea" label="Notes" rows="2" />
          <.input field={@form[:active]} type="checkbox" label="Active" />
        </div>
      </div>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary">Save</button>
        <.link
          navigate={~p"/admin/p/#{@source.project_id}/sourcing"}
          class="btn btn-ghost"
        >
          Cancel
        </.link>
      </div>
    </.form>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="card bg-base-100 shadow-sm mb-4">
      <div class="card-body gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <div class="flex-1 min-w-0">
            <p class="text-xs opacity-60">
              {if @source.last_run_at,
                do: "Last run #{Calendar.strftime(@source.last_run_at, "%b %-d at %-I:%M %p")}",
                else: "Never run"}
            </p>
          </div>

          <.link
            navigate={~p"/admin/p/#{@source.project_id}/sourcing/#{@source.id}/edit"}
            class="btn btn-sm btn-ghost"
          >
            Edit
          </.link>
          <%!-- Reviewing thirty rows one button at a time is how a review
                stops happening at all. The per-row buttons stay for the
                judgement calls; this is for the rest. --%>
          <button
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="run"
            phx-value-id={@source.id}
            data-confirm={run_confirmation(@plan)}
          >
            Run search
          </button>
        </div>

        <.run_progress progress={@progress} counts={@counts} source={@source} />

        <.plan_summary plan={@plan} id="run-plan" />
      </div>
    </div>

    <div role="tablist" class="tabs tabs-box mb-4">
      <button
        :for={status <- @views}
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

    <%!-- Each tab's own bulk add: the places with an address go to the drip,
          the ones with no website (but a phone) go to the call list. --%>
    <div
      :if={@status == "email" and @addable.email > 0}
      class="flex flex-wrap items-center gap-3 mb-3"
    >
      <button
        type="button"
        id="add-all-email"
        class="btn btn-sm btn-primary"
        phx-click="add_all"
        phx-value-kind="email"
        data-confirm={"Add #{@addable.email} with an email address to #{@source.project.name}, ready for a campaign?"}
      >
        <.icon name="hero-envelope" class="size-4" /> Add all {@addable.email} for email drip
      </button>
      <span class="text-xs opacity-60">They become prospects you can add to a campaign.</span>
    </div>

    <div
      :if={@status == "phone" and @addable.calls > 0}
      class="flex flex-wrap items-center gap-3 mb-3"
    >
      <button
        type="button"
        id="add-all-calls"
        class="btn btn-sm btn-primary"
        phx-click="add_all"
        phx-value-kind="calls"
        data-confirm={"Add #{@addable.calls} phone-only places to #{@source.project.name}'s call list?"}
      >
        <.icon name="hero-phone" class="size-4" /> Add all {@addable.calls} for calling
      </button>
      <span class="text-xs opacity-60">
        No email anywhere — they go on the call list and are never emailed.
      </span>
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Organisation</th>
              <th>Address</th>
              <th>Also</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@orgs == []}>
              <td colspan="4" class="text-center text-base-content/50 py-8">
                Nothing at this status{if @source.last_run_at, do: ".", else: " — run the search."}
              </td>
            </tr>

            <tr :for={org <- @orgs}>
              <td class="whitespace-nowrap">
                <div class="font-medium">{org.name}</div>
                <div class="text-xs text-base-content/50">
                  {humanize(org.segment)}
                  <span :if={org.city}>· {org.city}{if org.region, do: ", #{org.region}"}</span>
                  <span :if={org.fetched_at}>
                    · looked {Calendar.strftime(org.fetched_at, "%b %-d")}
                  </span>
                </div>
              </td>

              <%!-- The evidence, in the column you scan: the address, how it
                    was published, and one click to the page it was on. --%>
              <td class="text-sm">
                <div :if={org.email} class="font-mono text-xs">{org.email}</div>
                <div :if={org.email} class="text-xs text-base-content/50">
                  {presentation_phrase(org.email_presentation)}
                  <.link
                    :if={org.email_source_url}
                    href={org.email_source_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link"
                  >
                    see the page
                  </.link>
                </div>
                <div :if={!org.email && org.has_contact_form} class="text-xs text-base-content/50">
                  contact form only
                </div>
                <div :if={!org.email && !org.has_contact_form} class="text-xs text-base-content/50">
                  {no_address_note(org)}
                </div>
                <%!-- The sentence the notice was found in, on hover: a table
                      has no room for it, but it is what lets a reviewer judge
                      whether the notice really applies — "no soliciting" on a
                      door sign is not "no unsolicited commercial email". --%>
                <div
                  :if={org.no_solicitation}
                  class="text-xs text-warning mt-1 cursor-help"
                  title={org.notice_text}
                >
                  <.icon name="hero-exclamation-triangle" class="size-3" /> asked not to be solicited
                </div>
              </td>

              <td class="text-sm">
                <div :if={org.phone} class="text-xs">{org.phone}</div>
                <.link
                  :if={org.website}
                  href={org.website}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="link text-xs text-base-content/50"
                >
                  {pretty_host(org.website)}
                </.link>
              </td>

              <td class="text-right whitespace-nowrap">
                <button
                  :if={(org.email || org.phone) && !org.no_solicitation && org.status != "promoted"}
                  type="button"
                  class="btn btn-xs btn-primary"
                  phx-click="promote"
                  phx-value-org_id={org.id}
                >
                  {if org.email, do: "Add", else: "Call list"}
                </button>
                <button
                  :if={org.status != "promoted"}
                  type="button"
                  class="btn btn-xs btn-ghost"
                  phx-click="recrawl"
                  phx-value-id={org.id}
                >
                  Look again
                </button>
                <button
                  :if={Sourcing.view_of(org) not in ["added", "left_off"]}
                  type="button"
                  class="btn btn-xs btn-ghost"
                  phx-click="reject"
                  phx-value-id={org.id}
                  data-confirm={"Leave #{org.name} off the list?"}
                >
                  Not a fit
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  ## Wording

  defp no_address_note(%{status: "needs_website"}), do: "no website"
  defp no_address_note(%{reject_reason: "no_address_published"}), do: "no email on their website"
  defp no_address_note(%{reject_reason: nil}), do: "—"
  defp no_address_note(%{reject_reason: reason}), do: humanize(reason)

  defp label_for("email"), do: "Email"
  defp label_for("phone"), do: "Phone only"
  defp label_for("checking"), do: "Checking website"
  defp label_for("left_off"), do: "Left off"
  defp label_for("added"), do: "Added"
  defp label_for(other), do: humanize(other)

  # How the address was published, said rather than named. A reviewer glancing
  # down this column shouldn't have to know what "plain_text" means, and the
  # difference matters: an address only in prose is weaker evidence than one
  # behind a mailto link somebody put there to be written to.
  defp presentation_phrase("mailto"), do: "mailto link"
  defp presentation_phrase("cloudflare"), do: "hidden from scrapers"
  defp presentation_phrase("obfuscated"), do: "written out to dodge scrapers"
  defp presentation_phrase("plain_text"), do: "in the page text"
  defp presentation_phrase(other), do: humanize(other)

  attr :picker, :map, required: true
  attr :towns, :list, required: true
  attr :skipped, :any, required: true

  # Inside the source form so it needs no form of its own; its fields post
  # under `picker[...]`, which the save handler never reads.
  defp town_picker(assigns) do
    assigns = assign(assigns, :picked, picked(assigns.towns, assigns.skipped))

    ~H"""
    <div id="town-picker" class="rounded-box border border-base-300 p-3 space-y-3">
      <div>
        <p class="font-medium text-sm">Add towns</p>
        <p class="text-xs opacity-60">
          Pick a state and a population cutoff, or every town near one. Small towns reach rural
          businesses a big-town search misses.
        </p>
      </div>

      <div class={[
        "grid gap-2",
        if(@picker["mode"] == "radius",
          do: "sm:grid-cols-2 lg:grid-cols-5",
          else: "sm:grid-cols-3"
        )
      ]}>
        <.input
          type="select"
          id="picker-mode"
          name="picker[mode]"
          value={@picker["mode"]}
          options={[{"In a state", "state"}, {"Near a town", "radius"}]}
        />
        <.input
          type="select"
          id="picker-state"
          name="picker[state]"
          value={@picker["state"]}
          prompt="Choose a state"
          options={Towns.state_options()}
        />
        <.input
          :if={@picker["mode"] == "radius"}
          type="select"
          id="picker-center"
          name="picker[center]"
          value={@picker["center"]}
          prompt={if @picker["state"] == "", do: "Choose a state first", else: "Choose a town"}
          options={center_options(@picker["state"])}
          disabled={@picker["state"] == ""}
        />
        <.input
          :if={@picker["mode"] == "radius"}
          type="select"
          id="picker-miles"
          name="picker[miles]"
          value={@picker["miles"]}
          options={Enum.map(Towns.mile_options(), &{"within #{&1} miles", &1})}
        />
        <.input
          type="select"
          id="picker-population"
          name="picker[min_population]"
          value={@picker["min_population"]}
          options={Enum.map(Towns.population_options(), &{"#{format_number(&1)}+ people", &1})}
        />
      </div>

      <div :if={@towns != []} class="space-y-2">
        <div class="flex flex-wrap items-center gap-2 text-xs">
          <span class="opacity-70">
            {length(@picked)} of {count(length(@towns), "town", "towns")} ticked
          </span>
          <button type="button" class="btn btn-xs btn-ghost" phx-click="pick_all">All</button>
          <button type="button" class="btn btn-xs btn-ghost" phx-click="pick_none">None</button>
        </div>

        <div class="max-h-64 overflow-y-auto grid gap-x-4 gap-y-1 sm:grid-cols-2 pr-1">
          <label
            :for={town <- @towns}
            class="flex items-center gap-2 text-sm cursor-pointer"
          >
            <input
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={not MapSet.member?(@skipped, town.label)}
              phx-click="toggle_town"
              phx-value-label={town.label}
            />
            <span class="truncate">{town.label}</span>
            <span class="ml-auto text-xs opacity-50 whitespace-nowrap">
              {format_number(town.population)}{if Map.has_key?(town, :miles),
                do: " · #{round(town.miles)} mi"}
            </span>
          </label>
        </div>

        <button
          type="button"
          id="add-towns"
          class="btn btn-sm"
          phx-click="add_towns"
          disabled={@picked == []}
        >
          Add {count(length(@picked), "town", "towns")} to Where
        </button>
      </div>

      <p
        :if={@towns == [] and @picker["mode"] == "radius" and @picker["center"] != ""}
        class="text-xs opacity-60"
      >
        No towns that size within that distance.
      </p>
    </div>
    """
  end

  defp center_options(""), do: []

  defp center_options(state) do
    state |> Towns.in_state(1_000) |> Enum.map(& &1.label) |> Enum.sort()
  end

  attr :progress, :map, required: true
  attr :counts, :map, required: true
  attr :source, :any, required: true

  # Where a run has got to: the Google searches, then the website checks, then
  # done. Re-rendered every few seconds while it's going.
  defp run_progress(%{source: %{last_run_at: nil}} = assigns), do: ~H""

  defp run_progress(assigns) do
    total = assigns.counts |> Map.values() |> Enum.sum()
    checked = total - assigns.progress.checking

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:checked, checked)

    ~H"""
    <div id="run-progress" class="rounded-box bg-base-200/60 p-3 space-y-2 text-sm">
      <%= if @progress.done do %>
        <p class="flex items-center gap-2 font-medium text-success">
          <.icon name="hero-check-circle" class="size-5" />
          Done — every search has run and every website has been checked.
        </p>
      <% else %>
        <div :if={@progress.searches_total > 0}>
          <div class="flex justify-between text-xs mb-1">
            <span>
              Searching Google
              <span :if={@progress.searches_left == 0} class="text-success">· finished</span>
            </span>
            <span class="opacity-70">
              {@progress.searches_done} of {@progress.searches_total}
            </span>
          </div>
          <progress
            class="progress progress-primary w-full"
            value={@progress.searches_done}
            max={@progress.searches_total}
          />
        </div>

        <div :if={@total > 0}>
          <div class="flex justify-between text-xs mb-1">
            <span>Checking websites for an email address</span>
            <span class="opacity-70">{@progress.checking} left</span>
          </div>
          <progress class="progress progress-primary w-full" value={@checked} max={@total} />
        </div>

        <p :if={@progress.stalled > 0} class="flex flex-wrap items-center gap-2 text-xs">
          <span class="text-warning">
            {@progress.stalled} websites have no check queued, so this won't finish on its own.
          </span>
          <button type="button" class="btn btn-xs" phx-click="queue_missing">
            Queue them
          </button>
        </p>

        <p class="text-xs opacity-50">Updates by itself every few seconds.</p>
      <% end %>
    </div>
    """
  end

  attr :plan, :map, required: true
  attr :id, :string, required: true

  # What a run will do, in the order it matters: how much searching, what it
  # costs, and the exact phrases — so "rofing" or a stray state is caught here
  # rather than on the bill.
  defp plan_summary(%{plan: %{searches: 0}} = assigns) do
    ~H"""
    <div id={@id} class="text-xs opacity-60">
      Add something to look for and somewhere to look, and the searches it will run show up here.
    </div>
    """
  end

  defp plan_summary(assigns) do
    ~H"""
    <div id={@id} class="rounded-box bg-base-200/60 p-3 text-sm space-y-2">
      <p class="font-medium">
        {count(@plan.searches, "search", "searches")} across {count(@plan.towns, "town", "towns")}
        <span :if={@plan.max_cost > 0} class="font-normal opacity-70">
          · {count(@plan.min_requests, "request", "requests")}{if @plan.max_requests >
                                                                    @plan.min_requests,
                                                                  do:
                                                                    " to #{format_number(@plan.max_requests)}"} · about {money(
            @plan.min_cost
          )}{if @plan.max_cost > @plan.min_cost,
            do: "–#{money(@plan.max_cost)}"}
        </span>
      </p>
      <p :for={{state, towns} <- @plan.states} class="text-xs opacity-70">
        {state} becomes its {towns} towns of 5,000 or more.
      </p>
      <ul class="text-xs opacity-70 space-y-0.5">
        <li :for={{segment, phrases} <- @plan.trades}>
          <span class="font-medium">{humanize(segment)}</span>
          <span :if={phrases != []}>
            — searches {Enum.map_join(phrases, ", ", &~s("#{&1}"))}
          </span>
        </li>
      </ul>
      <p :if={@plan.max_cost > 0} class="text-xs opacity-50">
        Each search is 1 to 3 requests — Google returns 20 at a time, up to 60. The cost is at
        Google's list price; your billing console has the real rate.
      </p>
    </div>
    """
  end

  defp run_confirmation(%{max_cost: max_cost} = plan) when max_cost > 0,
    do:
      "Run #{format_number(plan.searches)} searches across #{format_number(plan.towns)} towns? " <>
        "About #{money(plan.min_cost)}–#{money(plan.max_cost)} at Google's list price."

  defp run_confirmation(plan), do: "Run #{format_number(plan.searches)} searches?"

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{format_number(n)} #{plural}"

  defp format_number(n) when n >= 1000,
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  defp format_number(n), do: Integer.to_string(n)

  defp money(amount) when amount < 1, do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)
  defp money(amount), do: "$" <> Integer.to_string(round(amount))

  # No apostrophes: they render as entities and read badly in a flash.
  defp add_all_message(kind, %{added: added, existing: existing, failed: failed}, source) do
    where_to =
      if kind == "email",
        do: "#{source.project.name} — add them to a campaign from its page",
        else: "the #{source.project.name} call list"

    [
      if(added > 0, do: "Added #{added} to #{where_to}.", else: "Nothing new to add."),
      existing > 0 && "#{existing} already there, so linked rather than added twice.",
      failed > 0 && "#{failed} could not be added."
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

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
