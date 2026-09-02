defmodule ColdForgeWeb.AdminLive.Campaigns do
  @moduledoc """
  The campaign list for a project, and creating one.

  There is no campaign *type* to choose. A campaign holds emails: one with no
  delay is a blast, several with delays is a drip. Making that a decision up
  front bought nothing and cost a whole extra concept.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Sequence
  alias ColdForge.Repo

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok, assign(socket, :project_id, project_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    campaigns =
      socket.assigns.project_id
      |> Outreach.list_sequences()
      |> Repo.preload(:steps)

    socket
    |> assign(:page_title, "Campaigns")
    |> assign(:page_subtitle, socket.assigns.current_project.name)
    |> assign(:campaigns, campaigns)
    |> assign(:stats, Map.new(campaigns, &{&1.id, Outreach.campaign_stats(&1.id)}))
    |> assign(:people, Map.new(campaigns, &{&1.id, Outreach.count_enrollments_by_status(&1.id)}))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New campaign")
    |> assign(:page_subtitle, socket.assigns.current_project.name)
    |> assign(:form, to_form(Outreach.change_sequence(%Sequence{})))
  end

  @impl true
  def handle_event("validate", %{"sequence" => params}, socket) do
    changeset =
      %Sequence{}
      |> Outreach.change_sequence(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"sequence" => params}, socket) do
    params = Map.put(params, "project_id", socket.assigns.project_id)

    case Outreach.create_sequence(params) do
      {:ok, campaign} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/admin/p/#{socket.assigns.project_id}/campaigns/#{campaign.id}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div class="flex justify-end mb-4">
      <.link navigate={~p"/admin/p/#{@project_id}/campaigns/new"} class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="size-4" /> New campaign
      </.link>
    </div>

    <div :if={@campaigns == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-paper-airplane" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No campaigns yet</h2>
        <p class="text-base-content/60 max-w-md">
          A campaign is a set of emails and the people who get them. Write one
          email for a single send, or several with delays for a follow-up
          sequence.
        </p>
        <.link navigate={~p"/admin/p/#{@project_id}/campaigns/new"} class="btn btn-primary mt-4">
          Create one
        </.link>
      </div>
    </div>

    <div :if={@campaigns != []} class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Campaign</th>
              <th>Status</th>
              <th class="text-right">People</th>
              <th class="text-right">Sent</th>
              <th class="text-right">Opened</th>
              <th class="text-right">Clicked</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @campaigns}>
              <td>
                <.link
                  navigate={~p"/admin/p/#{@project_id}/campaigns/#{c.id}"}
                  class="font-medium hover:text-primary"
                >
                  {c.name}
                </.link>
                <div class="text-xs text-base-content/50">{email_count(c)}</div>
              </td>
              <td><span class={["badge badge-sm", status_class(c.status)]}>{c.status}</span></td>
              <td class="text-right tabular-nums">{Map.get(@people[c.id], "active", 0)}</td>
              <td class="text-right tabular-nums">{@stats[c.id].sent}</td>
              <td class="text-right tabular-nums">{@stats[c.id].opened}</td>
              <td class={[
                "text-right tabular-nums",
                if(@stats[c.id].clicked > 0, do: "text-primary font-medium", else: "")
              ]}>
                {@stats[c.id].clicked}
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
    <div class="card bg-base-100 shadow-sm max-w-xl">
      <div class="card-body">
        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          id="campaign-form"
          class="space-y-4"
        >
          <.input field={@form[:name]} label="Campaign name" placeholder="Roofers — spring 2026" />
          <p class="text-xs text-base-content/50 -mt-2">Only you see this.</p>

          <details class="text-sm">
            <summary class="cursor-pointer text-base-content/60">
              Sending pace — the defaults are sensible, change them if you need
            </summary>

            <div class="mt-4 space-y-4">
              <div class="grid gap-4 sm:grid-cols-3">
                <.input
                  type="number"
                  field={@form[:send_window_start]}
                  label="From (hour)"
                  min="0"
                  max="23"
                />
                <.input
                  type="number"
                  field={@form[:send_window_end]}
                  label="Until (hour)"
                  min="1"
                  max="24"
                />
                <.input type="number" field={@form[:daily_cap]} label="Max per day" min="1" />
              </div>

              <fieldset>
                <legend class="text-sm font-medium mb-2">Send on</legend>
                <div class="flex flex-wrap gap-3">
                  <label :for={{label, num} <- days()} class="flex items-center gap-1.5 text-sm">
                    <input
                      type="checkbox"
                      name="sequence[send_days][]"
                      value={num}
                      checked={num in (Phoenix.HTML.Form.input_value(@form, :send_days) || [])}
                      class="checkbox checkbox-sm"
                    />
                    {label}
                  </label>
                </div>
              </fieldset>

              <p class="text-xs text-base-content/50">
                Hours are in {@current_project.timezone}. Anything falling outside the
                window waits for the next open slot rather than going out at 3am.
              </p>
            </div>
          </details>

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/admin/p/#{@project_id}/campaigns"} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Creating…">
              Create campaign
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp email_count(%{steps: steps}) do
    case length(steps) do
      0 -> "no emails yet"
      1 -> "1 email"
      n -> "#{n} emails"
    end
  end

  defp days do
    [{"Mon", 1}, {"Tue", 2}, {"Wed", 3}, {"Thu", 4}, {"Fri", 5}, {"Sat", 6}, {"Sun", 7}]
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("paused"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
