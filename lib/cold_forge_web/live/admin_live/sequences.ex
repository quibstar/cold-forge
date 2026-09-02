defmodule ColdForgeWeb.AdminLive.Sequences do
  @moduledoc "The sequence list for a project, plus creating one."
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Sequence

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok, assign(socket, :project_id, project_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    sequences = Outreach.list_sequences(socket.assigns.project_id)

    socket
    |> assign(:page_title, "Sequences")
    |> assign(:page_subtitle, socket.assigns.current_project.name)
    |> assign(:sequences, sequences)
    |> assign(:counts, Map.new(sequences, &{&1.id, Outreach.count_enrollments_by_status(&1.id)}))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New sequence")
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
    params =
      params
      |> Map.put("project_id", socket.assigns.project_id)
      |> Map.update("send_days", [], &normalize_days/1)

    case Outreach.create_sequence(params) do
      {:ok, sequence} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sequence created. Add your first email.")
         |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/sequences/#{sequence.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Checkbox groups arrive as strings; the schema wants ISO day integers.
  defp normalize_days(days) when is_list(days) do
    days |> Enum.reject(&(&1 == "")) |> Enum.map(&String.to_integer/1)
  end

  defp normalize_days(_), do: []

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div class="flex justify-end mb-4">
      <.link
        navigate={~p"/admin/p/#{@project_id}/sequences/new"}
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-plus" class="size-4" /> New sequence
      </.link>
    </div>

    <div :if={@sequences == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-queue-list" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">No sequences yet</h2>
        <p class="text-base-content/60 max-w-md">
          A sequence is an ordered set of emails with delays between them.
          Prospects enrol at step one and move through automatically.
        </p>
      </div>
    </div>

    <div class="grid gap-4 sm:grid-cols-2">
      <div :for={sequence <- @sequences} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-start justify-between gap-2">
            <.link
              navigate={~p"/admin/p/#{@project_id}/sequences/#{sequence.id}"}
              class="font-semibold hover:text-primary"
            >
              {sequence.name}
            </.link>
            <span class={["badge badge-sm shrink-0", status_class(sequence.status)]}>
              {sequence.status}
            </span>
          </div>

          <div class="text-sm text-base-content/60 mt-2">
            {Map.get(@counts[sequence.id], "active", 0)} active · {Map.get(
              @counts[sequence.id],
              "completed",
              0
            )} completed · {Map.get(@counts[sequence.id], "stopped", 0)} stopped
          </div>

          <div class="text-xs text-base-content/50 mt-1">
            Sends {sequence.send_window_start}:00–{sequence.send_window_end}:00,
            up to {sequence.daily_cap}/day
          </div>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm max-w-2xl">
      <div class="card-body">
        <.form
          id="sequence-form"
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input field={@form[:name]} label="Sequence name" placeholder="Roofers — spring 2026" />

          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              type="number"
              field={@form[:send_window_start]}
              label="Send from (hour)"
              min="0"
              max="23"
            />
            <.input
              type="number"
              field={@form[:send_window_end]}
              label="Send until (hour)"
              min="1"
              max="24"
            />
            <.input type="number" field={@form[:daily_cap]} label="Max per day" min="1" />
          </div>
          <p class="text-xs text-base-content/50 -mt-2">
            Hours are in the project's timezone. Anything falling outside the
            window is pushed to the next open slot rather than sent late at night.
          </p>

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

          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/admin/p/#{@project_id}/sequences"} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Create sequence
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp days do
    [{"Mon", 1}, {"Tue", 2}, {"Wed", 3}, {"Thu", 4}, {"Fri", 5}, {"Sat", 6}, {"Sun", 7}]
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("paused"), do: "badge-warning"
  defp status_class("archived"), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"
end
