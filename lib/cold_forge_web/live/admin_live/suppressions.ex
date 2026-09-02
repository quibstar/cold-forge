defmodule ColdForgeWeb.AdminLive.Suppressions do
  @moduledoc """
  The global do-not-contact list.

  Global rather than per-project on purpose: someone who opts out of one idea
  should not turn up in the next one's prospect list.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Do not contact")
     |> assign(:page_subtitle, "Applies across every project, not just the one they came from.")
     |> assign(:form, to_form(%{"email" => ""}, as: :suppression))
     |> load()}
  end

  defp load(socket), do: assign(socket, :suppressions, Outreach.list_suppressions())

  @impl true
  def handle_event("add", %{"suppression" => %{"email" => email}}, socket) do
    case String.trim(email) do
      "" ->
        {:noreply, socket}

      email ->
        Outreach.suppress(email, "manual")

        {:noreply,
         socket
         |> put_flash(:info, "#{email} will not be contacted.")
         |> assign(:form, to_form(%{"email" => ""}, as: :suppression))
         |> load()}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    suppression = Enum.find(socket.assigns.suppressions, &(to_string(&1.id) == id))
    if suppression, do: Outreach.delete_suppression(suppression)

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm mb-4">
      <div class="card-body">
        <.form
          id="suppression-form"
          for={@form}
          phx-submit="add"
          class="flex flex-col sm:flex-row gap-2 sm:items-end"
        >
          <div class="flex-1">
            <.input field={@form[:email]} label="Add an address" placeholder="someone@example.com" />
          </div>
          <button type="submit" class="btn btn-primary">Suppress</button>
        </.form>
      </div>
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Email</th>
              <th>Reason</th>
              <th>Added</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@suppressions == []}>
              <td colspan="4" class="text-center text-base-content/50 py-8">
                Nobody suppressed yet.
              </td>
            </tr>
            <tr :for={s <- @suppressions}>
              <td class="font-medium">{s.email}</td>
              <td><span class="badge badge-ghost badge-sm">{s.reason}</span></td>
              <td class="text-sm text-base-content/60">
                {Calendar.strftime(s.inserted_at, "%b %-d, %Y")}
              </td>
              <td class="text-right">
                <button
                  phx-click="remove"
                  phx-value-id={s.id}
                  data-confirm="Remove this address from the do-not-contact list?"
                  class="btn btn-xs btn-ghost text-error"
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
