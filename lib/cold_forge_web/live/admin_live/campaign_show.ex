defmodule ColdForgeWeb.AdminLive.CampaignShow do
  @moduledoc """
  One campaign, and everything about it: the emails, the people, the numbers.

  This is the hub the rest of the project hangs off. Writing an email, adding
  people and starting the campaign all happen here rather than being scattered
  across separate screens.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.EmailPreview

  alias ColdForge.{Outreach, Sending}
  alias ColdForge.Outreach.{Prospect, CampaignStep}

  @impl true
  def mount(%{"project_id" => project_id, "id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:campaign_id, id)
     |> load()}
  end

  defp load(socket) do
    campaign = Outreach.get_campaign!(socket.assigns.campaign_id)

    socket
    |> assign(:campaign, campaign)
    |> assign(:enrollments, Outreach.list_enrollments(campaign.id))
    |> assign(:people, Outreach.count_enrollments_by_status(campaign.id))
    |> assign(:stats, Outreach.campaign_stats(campaign.id))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.campaign.name)
    |> assign(:breadcrumbs, project_crumbs(socket))
    |> assign(:preview_step, nil)
    |> assign_preview_prospect()
  end

  defp apply_action(socket, :new_email, _params) do
    socket
    |> assign(:surveys, ColdForge.Survey.list_surveys(socket.assigns.project_id))
    |> assign(:page_title, "New email")
    |> assign(:breadcrumbs, campaign_crumbs(socket))
    |> assign(:step, %CampaignStep{})
    |> assign(:form, to_form(Outreach.change_step(%CampaignStep{})))
    |> assign_preview_prospect()
  end

  defp apply_action(socket, :edit_email, %{"step_id" => step_id}) do
    step = Outreach.get_step!(step_id)

    socket
    |> assign(:surveys, ColdForge.Survey.list_surveys(socket.assigns.project_id))
    |> assign(:page_title, "Email #{step.position}")
    |> assign(:breadcrumbs, campaign_crumbs(socket))
    |> assign(:step, step)
    |> assign(:form, to_form(Outreach.change_step(step)))
    |> assign_preview_prospect()
  end

  defp apply_action(socket, :people, _params) do
    enrolled = MapSet.new(socket.assigns.enrollments, & &1.prospect_id)

    candidates =
      socket.assigns.project_id
      |> Outreach.list_prospects()
      |> Enum.filter(&(Prospect.mailable?(&1) and &1.id not in enrolled))

    socket
    |> assign(:page_title, "Add people")
    |> assign(:breadcrumbs, campaign_crumbs(socket))
    |> assign(:candidates, candidates)
    |> assign(:selected, MapSet.new(candidates, & &1.id))
  end

  defp project_crumbs(socket) do
    [
      {"Projects", ~p"/admin/projects"},
      {socket.assigns.current_project.name, ~p"/admin/p/#{socket.assigns.project_id}"}
    ]
  end

  defp campaign_crumbs(socket) do
    project_crumbs(socket) ++ [{socket.assigns.campaign.name, campaign_path(socket.assigns)}]
  end

  # The preview needs somebody to render against. A real prospect is the honest
  # choice; the placeholder only shows up on an empty project.
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
            title: "Owner",
            unsubscribe_token: "preview"
          }
      end

    assign(socket, :preview_prospect, prospect)
  end

  ## Emails

  @impl true
  def handle_event("validate", %{"campaign_step" => params}, socket) do
    changeset =
      socket.assigns.step
      |> Outreach.change_step(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_email", %{"campaign_step" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new_email -> Outreach.create_step(socket.assigns.campaign, params)
        :edit_email -> Outreach.update_step(socket.assigns.step, params)
      end

    case result do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email saved.")
         |> push_navigate(to: campaign_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("preview_email", %{"id" => id}, socket) do
    {:noreply, assign(socket, :preview_step, Outreach.get_step!(id))}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :preview_step, nil)}
  end

  def handle_event("delete_email", %{"id" => id}, socket) do
    {:ok, :ok} = id |> Outreach.get_step!() |> Outreach.delete_step()
    {:noreply, socket |> put_flash(:info, "Email removed.") |> load()}
  end

  def handle_event("send_test", %{"subject" => subject, "body" => body}, socket) do
    to = socket.assigns.current_scope.user.email

    result =
      Sending.deliver_test(
        to,
        subject,
        body,
        socket.assigns.preview_prospect,
        socket.assigns.current_project,
        branded: socket.assigns.campaign.branded
      )

    case result do
      :ok -> {:noreply, put_flash(socket, :info, "Test sent to #{to}.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Test send failed: #{reason}")}
    end
  end

  ## People

  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("toggle_all", _params, socket) do
    all = MapSet.new(socket.assigns.candidates, & &1.id)

    selected =
      if MapSet.size(socket.assigns.selected) == MapSet.size(all), do: MapSet.new(), else: all

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("add_people", _params, socket) do
    {:ok, %{enrolled: enrolled, skipped: skipped}} =
      Outreach.enroll_prospects(socket.assigns.campaign, MapSet.to_list(socket.assigns.selected))

    note = if skipped > 0, do: " Skipped #{skipped} who can't be mailed.", else: ""

    {:noreply,
     socket
     |> put_flash(:info, "Added #{enrolled}.#{note}")
     |> push_navigate(to: campaign_path(socket.assigns))}
  end

  def handle_event("remove_person", %{"id" => id}, socket) do
    {:ok, _} = id |> Outreach.get_enrollment!() |> Outreach.stop_enrollment()
    {:noreply, socket |> put_flash(:info, "Removed.") |> load()}
  end

  ## Running

  def handle_event("start", _params, socket) do
    case Outreach.activate_campaign(socket.assigns.campaign) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Campaign is running.") |> load()}

      {:error, :no_steps} ->
        {:noreply, put_flash(socket, :error, "Write at least one email first.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not start the campaign.")}
    end
  end

  def handle_event("pause", _params, socket) do
    {:ok, _} = Outreach.pause_campaign(socket.assigns.campaign)
    {:noreply, socket |> put_flash(:info, "Paused.") |> load()}
  end

  def handle_event("toggle_branding", _params, socket) do
    {:ok, _} =
      Outreach.update_campaign(socket.assigns.campaign, %{
        branded: not socket.assigns.campaign.branded
      })

    {:noreply, load(socket)}
  end

  defp campaign_path(%{project_id: project_id, campaign_id: campaign_id}) do
    ~p"/admin/p/#{project_id}/campaigns/#{campaign_id}"
  end

  ## Render

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 mb-4">
      <span class={["badge", status_class(@campaign.status)]}>{@campaign.status}</span>
      <span class="text-sm text-base-content/60">
        {Map.get(@people, "active", 0)} waiting · {@stats.sent} sent · {@stats.opened} opened ·
        <span class={if(@stats.clicked > 0, do: "text-primary font-medium", else: "")}>
          {@stats.clicked} clicked
        </span>
      </span>

      <div class="ml-auto flex gap-2">
        <button :if={@campaign.status != "active"} phx-click="start" class="btn btn-sm btn-primary">
          <.icon name="hero-play" class="size-4" /> Start
        </button>
        <button :if={@campaign.status == "active"} phx-click="pause" class="btn btn-sm btn-warning">
          <.icon name="hero-pause" class="size-4" /> Pause
        </button>
      </div>
    </div>

    <div :if={@campaign.steps == []} class="alert alert-info mb-4">
      <.icon name="hero-information-circle" class="size-5 shrink-0" />
      <span>
        Write your first email below. One email on its own is a single send;
        add more with delays and they become follow-ups.
      </span>
    </div>

    <div class="grid gap-4 lg:grid-cols-3">
      <div class="lg:col-span-2 space-y-3">
        <%!-- Full bodies, not an excerpt. Reading the whole campaign in order is
        how you notice that email 2 repeats email 1's opening, or that the ask
        never actually appears — which a two-line clamp hides. --%>
        <div :for={step <- @campaign.steps} class="card bg-base-100 shadow-sm">
          <div class="card-body py-4">
            <div class="flex items-start justify-between gap-3">
              <div class="flex items-center gap-2 text-xs text-base-content/50 min-w-0">
                <span class="badge badge-sm badge-ghost shrink-0">Email {step.position}</span>
                <span :if={step.position == 1}>goes out when someone is added</span>
                <span :if={step.position > 1}>
                  {step.delay_days} {if step.delay_days == 1, do: "day", else: "days"} later
                </span>
              </div>
              <div class="flex gap-1 shrink-0">
                <button
                  phx-click="preview_email"
                  phx-value-id={step.id}
                  class="btn btn-xs btn-ghost"
                >
                  Preview
                </button>
                <.link
                  navigate={~p"/admin/p/#{@project_id}/campaigns/#{@campaign_id}/emails/#{step.id}"}
                  class="btn btn-xs btn-ghost"
                >
                  Edit
                </.link>
                <button
                  phx-click="delete_email"
                  phx-value-id={step.id}
                  data-confirm="Delete this email?"
                  class="btn btn-xs btn-ghost text-error"
                >
                  Delete
                </button>
              </div>
            </div>

            <div class="mt-2 border-t border-base-200 pt-3">
              <div class="text-xs text-base-content/40">Subject</div>
              <div class="font-medium">{step.subject}</div>

              <div class="text-xs text-base-content/40 mt-3">Body</div>
              <p class="text-sm text-base-content/70 whitespace-pre-line">{step.body}</p>
            </div>
          </div>
        </div>

        <.link
          navigate={~p"/admin/p/#{@project_id}/campaigns/#{@campaign_id}/emails/new"}
          class="btn btn-outline w-full"
        >
          <.icon name="hero-plus" class="size-4" />
          {if @campaign.steps == [], do: "Write the first email", else: "Add a follow-up"}
        </.link>
      </div>

      <div class="space-y-4">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">People</h2>
              <.link
                navigate={~p"/admin/p/#{@project_id}/campaigns/#{@campaign_id}/people"}
                class="btn btn-xs btn-primary"
              >
                Add
              </.link>
            </div>

            <p :if={@enrollments == []} class="text-sm text-base-content/50">
              Nobody added yet.
            </p>

            <ul class="space-y-2 max-h-96 overflow-y-auto">
              <li
                :for={e <- @enrollments}
                class="flex items-center justify-between gap-2 text-sm border-b border-base-200 pb-2 last:border-0"
              >
                <div class="min-w-0">
                  <div class="truncate">{Prospect.display_name(e.prospect)}</div>
                  <div class="text-xs text-base-content/50">
                    <span :if={e.status == "active" and e.next_send_at}>
                      email {e.current_position + 1} on {Calendar.strftime(e.next_send_at, "%b %-d")}
                    </span>
                    <span :if={e.status == "completed"}>finished</span>
                    <span :if={e.stopped_reason}>stopped — {e.stopped_reason}</span>
                  </div>
                </div>
                <button
                  :if={e.status == "active"}
                  phx-click="remove_person"
                  phx-value-id={e.id}
                  class="btn btn-xs btn-ghost text-error shrink-0"
                >
                  Remove
                </button>
              </li>
            </ul>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Sending</h2>
            <p class="text-sm text-base-content/60">
              {@campaign.send_window_start}:00–{@campaign.send_window_end}:00,
              up to {@campaign.daily_cap} a day, in {@current_project.timezone}.
            </p>

            <label class="flex items-start gap-3 cursor-pointer mt-2">
              <input
                type="checkbox"
                checked={@campaign.branded}
                phx-click="toggle_branding"
                class="checkbox checkbox-sm mt-0.5"
              />
              <span class="text-sm">
                <span class="font-medium">Branded HTML</span>
                <span class="block text-xs text-base-content/50">
                  Adds your logo and colour. Leave this off for cold outreach — a
                  designed template is the clearest "sent in bulk" signal there is.
                </span>
              </span>
            </label>
          </div>
        </div>
      </div>
    </div>

    <%!-- A modal rather than its own page: previewing is a glance you take
    while reading the campaign, and losing your place in the list to take it
    would be the wrong trade. --%>
    <div
      :if={@preview_step}
      class="fixed inset-0 z-[60] flex items-start justify-center p-4 sm:pt-[6vh]"
    >
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" phx-click="close_preview" />
      <div
        class="relative w-full max-w-3xl"
        phx-window-keydown="close_preview"
        phx-key="Escape"
      >
        <.email_preview
          id="step-preview"
          subject={@preview_step.subject}
          body={@preview_step.body}
          branded={@campaign.branded}
          prospect={@preview_prospect}
          project={@current_project}
          class=""
        />
        <button
          phx-click="close_preview"
          class="btn btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close preview"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  def render(%{live_action: :people} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between gap-2 mb-2">
          <p class="text-sm text-base-content/60">
            {MapSet.size(@selected)} of {length(@candidates)} selected. Anyone who
            unsubscribed, bounced or already replied isn't listed.
          </p>
          <button phx-click="toggle_all" class="btn btn-xs btn-ghost">Toggle all</button>
        </div>

        <div :if={@candidates == []} class="text-center text-base-content/50 py-8">
          Nobody left to add. Import some prospects first.
        </div>

        <ul class="max-h-[28rem] overflow-y-auto divide-y divide-base-200">
          <li :for={p <- @candidates} class="py-2">
            <label class="flex items-center gap-3 cursor-pointer">
              <input
                type="checkbox"
                checked={MapSet.member?(@selected, p.id)}
                phx-click="toggle"
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
          <.link navigate={campaign_path(assigns)} class="btn btn-ghost">Cancel</.link>
          <button
            phx-click="add_people"
            disabled={MapSet.size(@selected) == 0}
            class="btn btn-primary"
          >
            Add {MapSet.size(@selected)}
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
            for={@form}
            phx-change="validate"
            phx-submit="save_email"
            id="email-form"
            class="space-y-4"
          >
            <.input
              :if={@live_action == :edit_email or @campaign.steps != []}
              type="number"
              field={@form[:delay_days]}
              label="Days to wait after the previous email"
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

            <div>
              <label class="text-sm font-medium">Survey</label>
              <select name="campaign_step[survey_id]" class="select w-full mt-1">
                <option value="">— none —</option>
                <option
                  :for={survey <- @surveys}
                  value={survey.id}
                  selected={to_string(@form[:survey_id].value) == to_string(survey.id)}
                >
                  {survey.name}
                </option>
              </select>
              <p class="text-xs text-base-content/50 mt-1">
                Put <code class="text-primary">{"{{survey}}"}</code>
                in the body where it should appear. The first question renders with
                one-click answers; the rest are asked on the page they land on.
                <.link navigate={~p"/admin/p/#{@project_id}/surveys"} class="link">
                  Manage surveys
                </.link>
              </p>
            </div>

            <div class="text-xs text-base-content/50 space-y-1">
              <p>
                <code>{"{{first_name}}"}</code>
                <code>{"{{company}}"}</code>
                <code>{"{{title}}"}</code>
                <code>{"{{industry}}"}</code>
                — and <code>{"{{first_name|there}}"}</code>
                falls back when it's blank.
              </p>
              <p>
                <code>{"{{link}}"}</code>
                becomes a tracked link to your landing page. The unsubscribe line is
                added for you. <.link navigate={~p"/admin/guide"} class="link">How this works</.link>
              </p>
            </div>

            <div class="flex flex-wrap justify-end gap-2 pt-2">
              <.link navigate={campaign_path(assigns)} class="btn btn-ghost">Cancel</.link>
              <button
                type="button"
                phx-click={
                  JS.push("send_test",
                    value: %{
                      "subject" => @form[:subject].value || "",
                      "body" => @form[:body].value || ""
                    }
                  )
                }
                class="btn btn-outline"
              >
                <.icon name="hero-paper-airplane" class="size-4" /> Send test to me
              </button>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
                Save email
              </button>
            </div>
          </.form>
        </div>
      </div>

      <.email_preview
        subject={@form[:subject].value}
        body={@form[:body].value}
        branded={@campaign.branded}
        prospect={@preview_prospect}
        project={@current_project}
      />
    </div>
    """
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("paused"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
