defmodule ColdForgeWeb.AdminLive.SequenceShow do
  @moduledoc """
  The sequence editor: steps on the left, enrolled prospects on the right.

  The step form previews against a real prospect rather than showing raw merge
  tags, because "Hi {{first_name}}," and "Hi ," look identical until you send
  the second one to four hundred people.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Prospect, SequenceStep}
  alias ColdForge.Sending.Renderer

  @impl true
  def mount(%{"project_id" => project_id, "id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:sequence_id, id)
     |> load()}
  end

  defp load(socket) do
    sequence = Outreach.get_sequence!(socket.assigns.sequence_id)

    socket
    |> assign(:sequence, sequence)
    |> assign(:enrollments, Outreach.list_enrollments(sequence.id))
    |> assign(:counts, Outreach.count_enrollments_by_status(sequence.id))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.sequence.name)
    |> assign(:page_subtitle, socket.assigns.current_project.name)
    |> assign(:step, nil)
  end

  defp apply_action(socket, :new_step, _params) do
    socket
    |> assign(:page_title, "New email")
    |> assign(:page_subtitle, socket.assigns.sequence.name)
    |> assign(:step, %SequenceStep{})
    |> assign_form(Outreach.change_step(%SequenceStep{}))
    |> assign_preview_prospect()
  end

  defp apply_action(socket, :edit_step, %{"step_id" => step_id}) do
    step = Outreach.get_step!(step_id)

    socket
    |> assign(:page_title, "Step #{step.position}")
    |> assign(:page_subtitle, socket.assigns.sequence.name)
    |> assign(:step, step)
    |> assign_form(Outreach.change_step(step))
    |> assign_preview_prospect()
  end

  defp apply_action(socket, :enroll, _params) do
    enrolled_ids = MapSet.new(socket.assigns.enrollments, & &1.prospect_id)

    # Only offer people who can actually be mailed and aren't already in this
    # sequence — an enrol screen listing 400 unsubscribed contacts is noise.
    candidates =
      socket.assigns.project_id
      |> Outreach.list_prospects()
      |> Enum.filter(&(Prospect.mailable?(&1) and &1.id not in enrolled_ids))

    socket
    |> assign(:page_title, "Enroll prospects")
    |> assign(:page_subtitle, socket.assigns.sequence.name)
    |> assign(:candidates, candidates)
    |> assign(:selected, MapSet.new())
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  # The preview needs somebody to render against. A real prospect from this
  # project is the honest choice; the placeholder only appears on an empty list.
  defp assign_preview_prospect(socket) do
    prospect =
      case Outreach.list_prospects(socket.assigns.project_id) do
        [first | _] ->
          first

        [] ->
          %Prospect{
            first_name: "Sam",
            last_name: "Rivera",
            email: "sam@example.com",
            company: "Rivera Roofing",
            title: "Owner"
          }
      end

    assign(socket, :preview_prospect, prospect)
  end

  @impl true
  def handle_event("validate", %{"sequence_step" => params}, socket) do
    changeset =
      socket.assigns.step
      |> Outreach.change_step(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save_step", %{"sequence_step" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new_step -> Outreach.create_step(socket.assigns.sequence, params)
        :edit_step -> Outreach.update_step(socket.assigns.step, params)
      end

    case result do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email saved.")
         |> push_navigate(to: sequence_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete_step", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_step!() |> Outreach.delete_step()
    {:noreply, socket |> put_flash(:info, "Email removed.") |> load()}
  end

  def handle_event("activate", _params, socket) do
    case Outreach.activate_sequence(socket.assigns.sequence) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Sequence is live.") |> load()}

      {:error, :no_steps} ->
        {:noreply, put_flash(socket, :error, "Add at least one email before activating.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not activate the sequence.")}
    end
  end

  def handle_event("pause", _params, socket) do
    {:ok, _} = Outreach.pause_sequence(socket.assigns.sequence)
    {:noreply, socket |> put_flash(:info, "Sequence paused.") |> load()}
  end

  def handle_event("stop_enrollment", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_enrollment!() |> Outreach.stop_enrollment()
    {:noreply, socket |> put_flash(:info, "Enrollment stopped.") |> load()}
  end

  def handle_event("toggle_candidate", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all = MapSet.new(socket.assigns.candidates, & &1.id)

    selected =
      if MapSet.size(socket.assigns.selected) == MapSet.size(all), do: MapSet.new(), else: all

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("enroll", _params, socket) do
    {:ok, %{enrolled: enrolled, skipped: skipped}} =
      Outreach.enroll_prospects(socket.assigns.sequence, MapSet.to_list(socket.assigns.selected))

    message =
      if skipped > 0 do
        "Enrolled #{enrolled}. Skipped #{skipped} who can't be mailed."
      else
        "Enrolled #{enrolled}."
      end

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: sequence_path(socket.assigns))}
  end

  # Takes assigns, not a socket, so the render functions and the event handlers
  # can share it — `assigns` in a render body is the bare map.
  defp sequence_path(%{project_id: project_id, sequence_id: sequence_id}) do
    ~p"/admin/p/#{project_id}/sequences/#{sequence_id}"
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 mb-4">
      <span class={["badge", status_class(@sequence.status)]}>{@sequence.status}</span>
      <span class="text-sm text-base-content/60">
        {length(@sequence.steps)} emails · {Map.get(@counts, "active", 0)} active · {Map.get(
          @counts,
          "completed",
          0
        )} completed
      </span>

      <div class="ml-auto flex gap-2">
        <button
          :if={@sequence.status != "active"}
          phx-click="activate"
          class="btn btn-sm btn-primary"
        >
          Activate
        </button>
        <button :if={@sequence.status == "active"} phx-click="pause" class="btn btn-sm btn-warning">
          Pause
        </button>
        <.link
          navigate={~p"/admin/p/#{@project_id}/sequences/#{@sequence_id}/enroll"}
          class="btn btn-sm"
        >
          Enroll prospects
        </.link>
      </div>
    </div>

    <div class="grid gap-4 lg:grid-cols-3">
      <div class="lg:col-span-2 space-y-3">
        <div :for={step <- @sequence.steps} class="card bg-base-100 shadow-sm">
          <div class="card-body py-4">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2 text-xs text-base-content/50">
                  <span class="badge badge-sm badge-ghost">Step {step.position}</span>
                  <span :if={step.position == 1}>sent on enrollment</span>
                  <span :if={step.position > 1}>
                    {step.delay_days} {if step.delay_days == 1, do: "day", else: "days"} after the previous
                  </span>
                </div>
                <div class="font-medium mt-1 truncate">{step.subject}</div>
                <p class="text-sm text-base-content/60 mt-1 line-clamp-2 whitespace-pre-line">
                  {step.body}
                </p>
              </div>
              <div class="flex flex-col gap-1 shrink-0">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/sequences/#{@sequence_id}/steps/#{step.id}"}
                  class="btn btn-xs btn-ghost"
                >
                  Edit
                </.link>
                <button
                  phx-click="delete_step"
                  phx-value-id={step.id}
                  data-confirm="Delete this email from the sequence?"
                  class="btn btn-xs btn-ghost text-error"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>

        <.link
          navigate={~p"/admin/p/#{@project_id}/sequences/#{@sequence_id}/steps/new"}
          class="btn btn-outline w-full"
        >
          <.icon name="hero-plus" class="size-4" /> Add email
        </.link>
      </div>

      <div class="card bg-base-100 shadow-sm h-fit">
        <div class="card-body">
          <h2 class="card-title text-base">Enrolled</h2>
          <p :if={@enrollments == []} class="text-sm text-base-content/50">
            Nobody enrolled yet.
          </p>
          <ul class="space-y-2 max-h-[32rem] overflow-y-auto">
            <li
              :for={e <- @enrollments}
              class="flex items-center justify-between gap-2 text-sm border-b border-base-200 pb-2 last:border-0"
            >
              <div class="min-w-0">
                <div class="truncate">{Prospect.display_name(e.prospect)}</div>
                <div class="text-xs text-base-content/50">
                  step {e.current_position}
                  <span :if={e.next_send_at}>
                    · next {Calendar.strftime(e.next_send_at, "%b %-d %H:%M")} UTC
                  </span>
                  <span :if={e.stopped_reason}>· {e.stopped_reason}</span>
                </div>
              </div>
              <button
                :if={e.status == "active"}
                phx-click="stop_enrollment"
                phx-value-id={e.id}
                class="btn btn-xs btn-ghost text-error shrink-0"
              >
                Stop
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  def render(%{live_action: :enroll} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between gap-2 mb-2">
          <p class="text-sm text-base-content/60">
            {MapSet.size(@selected)} of {length(@candidates)} selected. People who
            unsubscribed, bounced or already replied aren't listed.
          </p>
          <button phx-click="select_all" class="btn btn-xs btn-ghost">Toggle all</button>
        </div>

        <div :if={@candidates == []} class="text-center text-base-content/50 py-8">
          Nobody left to enroll on this project.
        </div>

        <ul class="max-h-[28rem] overflow-y-auto divide-y divide-base-200">
          <li :for={p <- @candidates} class="py-2">
            <label class="flex items-center gap-3 cursor-pointer">
              <input
                type="checkbox"
                checked={MapSet.member?(@selected, p.id)}
                phx-click="toggle_candidate"
                phx-value-id={p.id}
                class="checkbox checkbox-sm"
              />
              <span class="min-w-0">
                <span class="block truncate">{Prospect.display_name(p)}</span>
                <span class="block text-xs text-base-content/50 truncate">
                  {p.email} <span :if={p.company}>· {p.company}</span>
                </span>
              </span>
            </label>
          </li>
        </ul>

        <div class="flex justify-end gap-2 pt-4">
          <.link navigate={sequence_path(assigns)} class="btn btn-ghost">Cancel</.link>
          <button
            phx-click="enroll"
            disabled={MapSet.size(@selected) == 0}
            class="btn btn-primary"
          >
            Enroll {MapSet.size(@selected)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="grid gap-4 lg:grid-cols-2">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <.form
            id="step-form"
            for={@form}
            phx-change="validate"
            phx-submit="save_step"
            class="space-y-4"
          >
            <.input
              :if={@live_action == :edit_step or length(@sequence.steps) > 0}
              type="number"
              field={@form[:delay_days]}
              label="Wait this many days after the previous email"
              min="0"
            />

            <.input field={@form[:subject]} label="Subject" placeholder="Quick question, {{company}}" />

            <.input
              type="textarea"
              field={@form[:body]}
              label="Body"
              rows="14"
              placeholder="Hi {{first_name|there}},&#10;&#10;..."
            />

            <div class="text-xs text-base-content/50 space-y-1">
              <p>
                Merge tags: <code>{"{{first_name}}"}</code>
                <code>{"{{last_name}}"}</code>
                <code>{"{{company}}"}</code>
                <code>{"{{title}}"}</code>
                <code>{"{{sender_name}}"}</code>
              </p>
              <p>
                Add a fallback with a pipe: <code>{"{{first_name|there}}"}</code>
                renders "there" when the field is empty.
              </p>
              <p>
                <code>{"{{link}}"}</code>
                becomes a tracked link to this project's landing page. Any URL you
                paste is tracked too. The unsubscribe line is added automatically.
              </p>
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={sequence_path(assigns)} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
                Save email
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm h-fit">
        <div class="card-body">
          <h2 class="card-title text-base">Preview</h2>
          <p class="text-xs text-base-content/50">
            Rendered for {Prospect.display_name(@preview_prospect)}.
          </p>

          <div class="mt-3 border border-base-300 rounded-lg overflow-hidden">
            <div class="px-4 py-2 bg-base-200 text-sm">
              <div class="text-xs text-base-content/50">Subject</div>
              <div class="font-medium">
                {preview(@form[:subject].value, @preview_prospect, @current_project)}
              </div>
            </div>
            <div class="px-4 py-3 text-sm whitespace-pre-line">
              {preview(@form[:body].value, @preview_prospect, @current_project)}
            </div>
            <div class="px-4 py-2 border-t border-base-300 text-xs text-base-content/50">
              — Unsubscribe link and postal address are appended on send.
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp preview(nil, _prospect, _project), do: ""
  defp preview("", _prospect, _project), do: ""
  defp preview(text, prospect, project), do: Renderer.preview(text, prospect, project)

  defp status_class("active"), do: "badge-success"
  defp status_class("paused"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
