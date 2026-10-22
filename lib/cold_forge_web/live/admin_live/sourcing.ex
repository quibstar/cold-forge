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
    |> assign_form(Sourcing.change_source(%Source{project_id: project_id}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sourcing.get_source!(id)

    socket
    |> assign(:page_title, source.name)
    |> assign(:page_subtitle, "What it looks for, and where.")
    |> assign(:breadcrumbs, [{"Sourcing", ~p"/admin/p/#{source.project_id}/sourcing"}])
    |> assign(:source, source)
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
    |> assign(:status, "fetched")
    |> load_results()
  end

  defp load_results(socket) do
    source = socket.assigns.source

    socket
    |> assign(:orgs, Sourcing.list_orgs(source_id: source.id, status: socket.assigns.status))
    |> assign(:counts, Sourcing.counts_for_source(source))
    |> assign(:ready_count, Sourcing.ready_count(source))
  end

  # The plan is worked out from whatever has been typed, valid or not, so the
  # cost of a typo or of a whole state is on screen before Save.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset))
    |> assign(:plan, Source.plan(Ecto.Changeset.apply_changes(changeset)))
  end

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

  def handle_event("promote_ready", _params, socket) do
    source = socket.assigns.source
    {:ok, %{promoted: promoted, failed: failed}} = Sourcing.promote_ready(source)

    message =
      case {promoted, failed} do
        {0, 0} -> "Nothing ready to add."
        {n, 0} -> "Added #{n} to #{source.project.name}."
        # No apostrophe: it renders as an entity and reads badly in a flash.
        {n, f} -> "Added #{n} to #{source.project.name}. #{f} skipped, already there."
      end

    {:noreply, socket |> put_flash(:info, message) |> load_results()}
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
            60 results, so a state is searched town by town — every town of 5,000+.
          </p>

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
            :if={@ready_count > 0}
            type="button"
            class="btn btn-sm"
            phx-click="promote_ready"
            data-confirm={"Add all #{@ready_count} to #{@source.project.name}?"}
          >
            Add all {@ready_count}
          </button>
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

        <.plan_summary plan={@plan} id="run-plan" />
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
                  {if org.reject_reason, do: humanize(org.reject_reason), else: "—"}
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
                  :if={org.status not in ["promoted", "rejected"]}
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

  defp label_for("fetched"), do: "Found an address"
  defp label_for("discovered"), do: "Waiting to crawl"
  defp label_for("needs_website"), do: "No website yet"
  defp label_for("rejected"), do: "Left off"
  defp label_for("promoted"), do: "Prospects"
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
