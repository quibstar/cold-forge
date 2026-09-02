defmodule ColdForgeWeb.AdminLive.Messages do
  @moduledoc """
  The activity log: what actually went out, and what came back.

  Clicks are the signal worth trusting here. Opens are recorded but shown
  quietly — Gmail and Outlook prefetch tracking pixels, so an "open" is
  frequently a machine.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.{Outreach, Tracking}
  alias ColdForge.Outreach.Prospect

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok, assign(socket, :project_id, project_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Activity")
    |> assign(:page_subtitle, socket.assigns.current_project.name)
    |> assign(:messages, Outreach.list_messages(socket.assigns.project_id))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    message = Outreach.get_message!(id)

    socket
    |> assign(:page_title, message.subject)
    |> assign(:page_subtitle, message.prospect.email)
    |> assign(:message, message)
    |> assign(:clicks, Tracking.list_clicks(message.id))
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>To</th>
              <th>Subject</th>
              <th>Status</th>
              <th class="text-right">Opens</th>
              <th class="text-right">Clicks</th>
              <th>Sent</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@messages == []}>
              <td colspan="6" class="text-center text-base-content/50 py-8">
                Nothing sent yet.
              </td>
            </tr>
            <tr :for={m <- @messages}>
              <td class="text-sm">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/messages/#{m.id}"}
                  class="font-medium hover:text-primary"
                >
                  {Prospect.display_name(m.prospect)}
                </.link>
                <div class="text-xs text-base-content/50">{m.prospect.email}</div>
              </td>
              <td class="text-sm max-w-xs truncate">{m.subject}</td>
              <td><span class={["badge badge-sm", status_class(m.status)]}>{m.status}</span></td>
              <td class="text-right tabular-nums text-sm text-base-content/60">{m.open_count}</td>
              <td class={[
                "text-right tabular-nums text-sm",
                if(clicks(m) > 0, do: "text-primary font-medium", else: "text-base-content/60")
              ]}>
                {clicks(m)}
              </td>
              <td class="text-sm text-base-content/60 whitespace-nowrap">
                <span :if={m.sent_at}>{Calendar.strftime(m.sent_at, "%b %-d, %H:%M")}</span>
                <span :if={is_nil(m.sent_at)}>—</span>
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
          <div class="text-sm text-base-content/60 border-b border-base-200 pb-3">
            <div><span class="text-base-content/40">To:</span> {@message.prospect.email}</div>
            <div><span class="text-base-content/40">Subject:</span> {@message.subject}</div>
          </div>
          <%!-- The stored body is exactly what was sent, tokenised links and
          all — so this shows the real URLs the recipient saw. --%>
          <pre class="text-sm whitespace-pre-wrap font-sans mt-3">{@message.body}</pre>
        </div>
      </div>

      <div class="space-y-4">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Delivery</h2>
            <dl class="text-sm space-y-1">
              <div class="flex justify-between gap-2">
                <dt class="text-base-content/50">Status</dt>
                <dd>
                  <span class={["badge badge-sm", status_class(@message.status)]}>{@message.status}</span>
                </dd>
              </div>
              <div :if={@message.sent_at} class="flex justify-between gap-2">
                <dt class="text-base-content/50">Sent</dt>
                <dd>{Calendar.strftime(@message.sent_at, "%b %-d, %Y %H:%M")} UTC</dd>
              </div>
              <div class="flex justify-between gap-2">
                <dt class="text-base-content/50">Opens</dt>
                <dd>{@message.open_count}</dd>
              </div>
              <div :if={@message.error} class="pt-2">
                <dt class="text-base-content/50">Error</dt>
                <dd class="text-error text-xs break-words">{@message.error}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Links</h2>
            <p :if={@message.tracked_links == []} class="text-sm text-base-content/50">
              No tracked links in this email.
            </p>
            <ul class="space-y-2">
              <li :for={link <- @message.tracked_links} class="text-sm">
                <div class="truncate text-base-content/70">{link.destination_url}</div>
                <div class="text-xs text-base-content/50">
                  {link.click_count} {if link.click_count == 1, do: "click", else: "clicks"}
                  <span :if={link.first_clicked_at}>
                    · first {Calendar.strftime(link.first_clicked_at, "%b %-d, %H:%M")}
                  </span>
                </div>
              </li>
            </ul>

            <div :if={@clicks != []} class="mt-3 pt-3 border-t border-base-200">
              <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-2">
                Click log
              </h3>
              <ul class="space-y-1 text-xs text-base-content/60">
                <li :for={click <- @clicks}>
                  {Calendar.strftime(click.clicked_at, "%b %-d, %H:%M")} · {click.ip}
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp clicks(message), do: Enum.sum(Enum.map(message.tracked_links, & &1.click_count))

  defp status_class("sent"), do: "badge-info"
  defp status_class("pending"), do: "badge-ghost"
  defp status_class("failed"), do: "badge-error"
  defp status_class("bounced"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"
end
