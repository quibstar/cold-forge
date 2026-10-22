defmodule ColdForgeWeb.AdminLive.Sourcing do
  @moduledoc """
  The review queue: everything the crawler found, and the decision about each.

  This page exists because nothing should reach a send list unlooked-at. The
  crawler is good at reading a page and bad at judging whether an organisation
  is worth writing to — a glazier is not a roofing prospect however cleanly its
  address parsed. So promotion is a click a person makes, with the evidence in
  front of them: the address, how it was published, and a link to the exact
  page it came from.

  The rejected rows are on purpose too. "No address published" is the most
  common outcome and it is an answer, not a failure: those organisations have a
  phone number and belong on the call list.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Sourcing

  @statuses ~w(fetched discovered needs_website rejected promoted)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sourcing")
     |> assign(:page_subtitle, "What the crawler found, and what you want done with it.")
     |> assign(:projects, Outreach.list_projects())
     |> assign(:statuses, @statuses)
     |> assign(:status, "fetched")
     |> assign(:segment, "all")
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(
      :orgs,
      Sourcing.list_orgs(status: socket.assigns.status, segment: socket.assigns.segment)
    )
    |> assign(:counts, Sourcing.counts_by_status())
    |> assign(:segments, Sourcing.segments_present())
  end

  @impl true
  def handle_event("status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  def handle_event("segment", %{"segment" => segment}, socket) do
    {:noreply, socket |> assign(:segment, segment) |> load()}
  end

  def handle_event("promote", %{"project_id" => ""}, socket) do
    {:noreply, put_flash(socket, :error, "Pick a project first.")}
  end

  def handle_event("promote", %{"org_id" => id, "project_id" => project_id}, socket) do
    org = Sourcing.get_org!(id)

    case Sourcing.promote(org, project_id) do
      {:ok, {prospect, _org}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{prospect.company} is now a prospect.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't promote: #{describe(reason)}")}
    end
  end

  def handle_event("reject", %{"id" => id, "reason" => reason}, socket) do
    {:ok, _} = id |> Sourcing.get_org!() |> Sourcing.reject(reason)
    {:noreply, socket |> put_flash(:info, "Left off the list.") |> load()}
  end

  def handle_event("recrawl", %{"id" => id}, socket) do
    org = Sourcing.get_org!(id)

    case Sourcing.enqueue_crawls([org]) do
      1 -> {:noreply, put_flash(socket, :info, "Queued another look at #{org.name}.")}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't queue that.")}
    end
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp describe(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 items-center mb-4">
      <div role="tablist" class="tabs tabs-box">
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

      <form id="sourcing-segment-filter" phx-change="segment" class="ml-auto">
        <select name="segment" class="select select-bordered select-sm">
          <option value="all" selected={@segment == "all"}>Every segment</option>
          <option :for={segment <- @segments} value={segment} selected={@segment == segment}>
            {humanize_segment(segment)}
          </option>
        </select>
      </form>
    </div>

    <p :if={@orgs == []} class="text-sm opacity-70 py-8 text-center">
      Nothing at this status.
    </p>

    <div class="grid gap-3">
      <div :for={org <- @orgs} class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-start gap-2">
            <div class="flex-1 min-w-0">
              <h3 class="font-semibold truncate">{org.name}</h3>
              <p class="text-xs opacity-70">
                {humanize_segment(org.segment)}
                <span :if={org.city}>· {org.city}{if org.region, do: ", #{org.region}"}</span>
                · found via {org.source}
              </p>
            </div>
            <span class={["badge", badge_class(org.status)]}>{label_for(org.status)}</span>
          </div>

          <%!-- The evidence. A reviewer deciding whether to write to someone
                should see the address, how it was published, and be one click
                from the page it was on. --%>
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
              This page asks not to be solicited, so the address is not usable.
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
            <span :if={org.reject_reason}>reason: {humanize_segment(org.reject_reason)}</span>
          </div>

          <div :if={org.status not in ["promoted"]} class="flex flex-wrap gap-2 items-center">
            <form
              :if={org.email || org.phone}
              id={"promote-#{org.id}"}
              phx-submit="promote"
              class="flex gap-2 items-center"
            >
              <input type="hidden" name="org_id" value={org.id} />
              <select name="project_id" class="select select-bordered select-sm">
                <option value="">Add to project…</option>
                <option :for={project <- @projects} value={project.id}>{project.name}</option>
              </select>
              <button type="submit" class="btn btn-sm btn-primary" disabled={org.no_solicitation}>
                {if org.email, do: "Add as prospect", else: "Add to call list"}
              </button>
            </form>

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
              phx-value-reason="out_of_segment"
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

  # Assigns used by the template that never change.
  defp label_for("fetched"), do: "Found an address"
  defp label_for("discovered"), do: "Waiting to crawl"
  defp label_for("needs_website"), do: "No website yet"
  defp label_for("rejected"), do: "Left off"
  defp label_for("promoted"), do: "Prospects"
  defp label_for(other), do: humanize_segment(other)

  defp badge_class("fetched"), do: "badge-success"
  defp badge_class("promoted"), do: "badge-primary"
  defp badge_class("rejected"), do: "badge-ghost"
  defp badge_class(_status), do: "badge-neutral"

  defp humanize_segment(nil), do: ""

  defp humanize_segment(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp pretty_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> url
    end
  end
end
