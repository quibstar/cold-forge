defmodule ColdForgeWeb.AdminLive.CallProspect do
  @moduledoc """
  One prospect: everything you need on the phone, and what happened after.

  Lifted from the page this list used to live on in ExteriorPro, because that
  page was built around the two minutes before a call rather than as a record
  to be administered — who they are, what they run now, what was said last
  time, and the script, open beside it while you talk.

  It is a page rather than the panel beside the call queue, which is what it
  started as here. A panel put a three-thousand-pixel script into a column
  sized for a summary card: below the `lg` breakpoint it landed under fifty
  queue rows, so clicking a prospect looked like nothing happening at all, and
  above it the phone number and the outcome buttons scrolled away from you.
  The queue is still the way in; it navigates here now.

  The debrief fields are part of the same form as the notes rather than a panel
  of their own. They get filled in during the same thirty seconds, and anything
  that hides them behind a disclosure makes them look like a separate job that
  can be left for later — which is when they stop being filled in at all.

  Logging a call moves the prospect on by itself: `ColdForge.Calling.log_call/2`
  decides the next slot, and whether the email sequence should stop. The status
  can also be set by hand, because "replied" rarely arrives as a phone call and
  without the picker a wrong status had no way back.

  History is editable and deletable. A call logged against the wrong company is
  the mistake people actually make, and an append-only log of a cold-call list
  is a filing cabinet nobody can correct.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.{Calling, Outreach}
  alias ColdForge.Calling.{Call, Scripts}
  alias ColdForge.Outreach.{CallScripts, Prospect}

  @impl true
  def mount(%{"project_id" => project_id, "id" => id}, _session, socket) do
    prospect = Outreach.get_prospect!(id)

    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, Prospect.display_name(prospect))
     |> assign(:page_subtitle, "Prospect")
     |> assign(:breadcrumbs, [
       {"Projects", ~p"/admin/projects"},
       {"Calls", ~p"/admin/p/#{project_id}/calls"}
     ])
     |> assign(:prospect, prospect)
     |> assign(:script_tab, CallScripts.default_tab(prospect, socket.assigns.current_project))
     |> assign(editing_id: nil, edit_form: nil)
     |> load()
     |> assign_call_form()}
  end

  defp load(socket) do
    prospect = socket.assigns.prospect

    socket
    |> assign(:history, Calling.list_calls(prospect.id))
    |> assign(:next_script, Calling.next_script(prospect.id))
  end

  defp reload(socket) do
    socket
    |> assign(:prospect, Outreach.get_prospect!(socket.assigns.prospect.id))
    |> load()
  end

  defp assign_call_form(socket) do
    assign(
      socket,
      :call_form,
      to_form(Call.changeset(%Call{outcome: "connected"}, %{}), id: "log-call")
    )
  end

  @impl true
  def handle_event("script_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :script_tab, tab)}

  def handle_event("log_call", %{"call" => params}, socket) do
    case Calling.log_call(socket.assigns.prospect, params) do
      {:ok, _call} ->
        {:noreply,
         socket
         |> reload()
         |> assign_call_form()
         |> put_flash(:info, "Call logged.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :call_form, to_form(changeset, id: "log-call"))}
    end
  end

  # Set by hand, alongside the statuses a call implies. A mis-logged call used
  # to leave the status wrong with nothing to correct it.
  def handle_event("set_status", %{"status" => status}, socket) do
    case Outreach.update_prospect(socket.assigns.prospect, %{"status" => status}) do
      {:ok, prospect} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Marked #{status_label(prospect.status)}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That isn't a status.")}
    end
  end

  def handle_event("edit_call", %{"id" => id}, socket) do
    call = Calling.get_call!(id)

    {:noreply,
     socket
     |> assign(:editing_id, call.id)
     |> assign(:edit_form, to_form(Call.changeset(call, %{}), id: "edit-call-#{call.id}"))}
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing_id: nil, edit_form: nil)}

  def handle_event("save_call", %{"call" => params}, socket) do
    call = Calling.get_call!(socket.assigns.editing_id)

    case Calling.update_call(call, params) do
      {:ok, _call} ->
        {:noreply,
         socket
         |> reload()
         |> assign(editing_id: nil, edit_form: nil)
         |> put_flash(:info, "Call updated.")}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :edit_form,
           to_form(changeset, id: "edit-call-#{socket.assigns.editing_id}")
         )}
    end
  end

  def handle_event("delete_call", %{"id" => id}, socket) do
    {:ok, _prospect} = id |> Calling.get_call!() |> Calling.delete_call()

    {:noreply,
     socket
     |> reload()
     |> assign(editing_id: nil, edit_form: nil)
     |> put_flash(:info, "Call deleted.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="space-y-6">
      <.link navigate={~p"/admin/p/#{@project_id}/calls"} class="text-sm text-primary hover:underline">
        ← Back to the queue
      </.link>

      <%!-- The script rides in a trailing column so it can stay open beside the
      call while you work down the page. Below xl it stacks on top, which is the
      right order on a narrow screen: you read it before you dial. 30rem rather
      than 24 — these are spoken scripts, and at 24 a sentence broke into three
      ragged lines, which is hard to read aloud. --%>
      <div class="flex flex-col xl:flex-row gap-6 xl:items-start">
        <aside
          :if={CallScripts.any?(@prospect, @current_project)}
          class="xl:w-[30rem] xl:shrink-0 xl:order-last"
        >
          <.call_script prospect={@prospect} project={@current_project} tab={@script_tab} />
        </aside>

        <div class="flex-1 min-w-0 max-w-4xl space-y-6">
          <%!-- The calling card: everything you want in front of you while the
          phone is ringing, which is why it is one block and not a set of tabs. --%>
          <section class="rounded-2xl border border-base-300 bg-base-100 p-6">
            <div class="flex flex-wrap items-start gap-4">
              <div class="min-w-0">
                <h2 class="text-xl font-bold">{Prospect.display_name(@prospect)}</h2>
                <p :if={contact_line(@prospect)} class="text-base-content/70">
                  {contact_line(@prospect)}
                </p>
              </div>
              <%!-- A picker, not a badge: calls move it, and so can a person.
              Saves on change — a second "Save" button for a one-field form is a
              click that teaches nothing. --%>
              <form id="prospect-status" phx-change="set_status" class="ml-auto">
                <select name="status" aria-label="Status" class="select select-bordered select-sm">
                  <option
                    :for={status <- Prospect.statuses()}
                    value={status}
                    selected={status == @prospect.status}
                  >
                    {status_label(status)}
                  </option>
                </select>
              </form>
            </div>

            <dl class="mt-5 grid sm:grid-cols-2 gap-x-8 gap-y-3 text-sm">
              <div :if={@prospect.phone} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Phone</dt>
                <dd>
                  <%!-- Lists put "See website" and "— look up —" in the phone
                  column. A tel: link around either is dead but looks live, so
                  the presence of actual digits decides. --%>
                  <a
                    :if={Prospect.dialable?(@prospect)}
                    href={"tel:#{@prospect.phone}"}
                    class="font-medium text-primary hover:underline tabular-nums"
                  >
                    {@prospect.phone}
                  </a>
                  <span :if={not Prospect.dialable?(@prospect)} class="text-base-content/70">
                    <span class="badge badge-xs badge-warning">no number</span>
                    {@prospect.phone}
                  </span>
                </dd>
              </div>
              <div :if={@prospect.email} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Email</dt>
                <dd>
                  <a href={"mailto:#{@prospect.email}"} class="text-primary hover:underline">
                    {@prospect.email}
                  </a>
                </dd>
              </div>
              <div :if={@prospect.website} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Website</dt>
                <dd class="truncate">{@prospect.website}</dd>
              </div>
              <div :if={where(@prospect)} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Where</dt>
                <dd>{where(@prospect)}</dd>
              </div>
              <div :if={Prospect.custom_field(@prospect, "current_software")} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Runs</dt>
                <dd class="font-medium">{Prospect.custom_field(@prospect, "current_software")}</dd>
              </div>
              <div :if={Prospect.custom_field(@prospect, "employee_estimate")} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Size</dt>
                <dd>{Prospect.custom_field(@prospect, "employee_estimate")}</dd>
              </div>
              <div :if={Prospect.fit(@prospect)} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Fit</dt>
                <dd>{Prospect.fit(@prospect)}</dd>
              </div>
              <div :if={@prospect.source} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Source</dt>
                <dd class="text-base-content/70">{@prospect.source}</dd>
              </div>
              <div :if={@prospect.next_call_at} class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Next</dt>
                <dd class="tabular-nums">
                  {Calendar.strftime(@prospect.next_call_at, "%B %-d")}
                </dd>
              </div>
            </dl>

            <p :if={@prospect.notes} class="mt-4 text-sm whitespace-pre-wrap text-base-content/80">
              {@prospect.notes}
            </p>
          </section>

          <%!-- The numbered voicemail, which is a different thing from the
          scripts beside it: those are written for this one shop, this one is
          the next in a four-message cadence and knows which have been left. --%>
          <section
            :if={@next_script && Scripts.render(@next_script, @prospect, @current_project)}
            class="rounded-2xl border border-base-300 bg-base-100 p-6"
          >
            <h3 class="font-semibold">
              Voicemail {@next_script}
              <span class="font-normal text-base-content/50">— {script_note(@next_script)}</span>
            </h3>
            <p class="mt-2 text-sm leading-relaxed whitespace-pre-line bg-base-200 rounded-lg p-4">
              {Scripts.render(@next_script, @prospect, @current_project)}
            </p>
          </section>

          <p :if={is_nil(@next_script)} class="text-sm text-base-content/50">
            All four voicemails have been left. There is no fifth message that helps —
            this is a call to have or a file to close.
          </p>

          <section class="rounded-2xl border border-base-300 bg-base-100 p-6">
            <h3 class="font-semibold">After the call</h3>
            <.form id="log-call-form" for={@call_form} phx-submit="log_call" class="mt-4 space-y-4">
              <div class="grid sm:grid-cols-2 gap-4">
                <.input
                  field={@call_form[:outcome]}
                  type="select"
                  label="What happened"
                  options={Enum.map(Call.outcomes(), &{Call.label(&1), &1})}
                />
                <.input name="call[next_call_on]" value="" type="date" label="Call back on" />
              </div>

              <.input
                field={@call_form[:notes]}
                type="textarea"
                label="Notes"
                placeholder="What was said, in their words where you can manage it."
              />

              <p class="pt-2 font-medium text-sm">
                Pain debrief — fill in if you got a real conversation
              </p>

              <.call_debrief_fields form={@call_form} />

              <button type="submit" class="btn btn-primary">Log the call</button>
            </.form>
          </section>

          <section class="space-y-3">
            <h3 class="font-semibold">
              History <span class="font-normal text-base-content/50">({length(@history)})</span>
            </h3>

            <p :if={@history == []} class="text-sm text-base-content/60">Nothing logged yet.</p>

            <div :for={call <- @history} class="rounded-xl border border-base-300 bg-base-100 p-4">
              <.form
                :if={@editing_id == call.id}
                id={"edit-call-#{call.id}"}
                for={@edit_form}
                phx-submit="save_call"
                class="space-y-4"
              >
                <div class="grid sm:grid-cols-2 gap-4">
                  <.input
                    field={@edit_form[:outcome]}
                    type="select"
                    label="What happened"
                    options={Enum.map(Call.outcomes(), &{Call.label(&1), &1})}
                  />
                  <.input field={@edit_form[:called_at]} type="datetime-local" label="When" />
                </div>
                <.input field={@edit_form[:notes]} type="textarea" label="Notes" />
                <.call_debrief_fields form={@edit_form} />
                <div class="flex items-center gap-3">
                  <button type="submit" class="btn btn-primary btn-sm">Save</button>
                  <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">
                    Cancel
                  </button>
                </div>
              </.form>

              <div :if={@editing_id != call.id} class="space-y-2">
                <div class="flex flex-wrap items-baseline gap-3 text-sm">
                  <span class="font-medium">{Call.label(call.outcome)}</span>
                  <span class="text-base-content/50 tabular-nums">
                    {Calendar.strftime(call.called_at, "%b %-d, %Y")}
                  </span>
                  <span :if={call.category} class="badge badge-sm badge-ghost">
                    {call.category}
                    <span :if={call.severity} class="ml-1 tabular-nums">· {call.severity}/5</span>
                  </span>
                  <div class="ml-auto flex items-center gap-1">
                    <button
                      type="button"
                      phx-click="edit_call"
                      phx-value-id={call.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      phx-click="delete_call"
                      phx-value-id={call.id}
                      data-confirm="Delete this call? The attempt count and last-called date are recomputed from what's left."
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </div>
                </div>

                <p :if={call.notes not in [nil, ""]} class="text-sm whitespace-pre-wrap">
                  {call.notes}
                </p>

                <dl
                  :if={call.pain || call.what_they_like || call.switch_objection}
                  class="text-sm space-y-1 pt-1"
                >
                  <div :if={call.what_they_like} class="flex gap-2">
                    <dt class="text-base-content/50 shrink-0">Likes</dt>
                    <dd>{call.what_they_like}</dd>
                  </div>
                  <div :if={call.pain} class="flex gap-2">
                    <dt class="text-base-content/50 shrink-0">Pain</dt>
                    <dd>{call.pain}</dd>
                  </div>
                  <div :if={call.switch_objection} class="flex gap-2">
                    <dt class="text-base-content/50 shrink-0">Blocker</dt>
                    <dd>{call.switch_objection}</dd>
                  </div>
                </dl>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :prospect, :map, required: true
  attr :project, :map, required: true
  attr :tab, :string, required: true

  # What to say, in the order it gets said. Verbatim rather than paraphrased:
  # the wording is the point of a script, and somebody reading it cold needs the
  # exact sentence, not a summary of its intent.
  #
  # Three ways to open the same call, and the choice is made mid-dial, so they
  # are tabs on one card rather than three cards to scroll between. A tab this
  # prospect has no script for is not drawn at all: an empty tab is a thing you
  # click once, find nothing in, and never trust again.
  defp call_script(assigns) do
    assigns =
      assigns
      |> assign(:tabs, CallScripts.available(assigns.prospect, assigns.project))
      |> assign(:parts, CallScripts.parts(assigns.prospect, assigns.project, assigns.tab))

    ~H"""
    <section class="rounded-2xl border border-primary/25 bg-base-100 overflow-hidden xl:sticky xl:top-20">
      <div class="px-5 py-3 bg-primary/5 border-b border-primary/15 flex flex-wrap items-center gap-2">
        <h2 class="font-semibold mr-1">What to say</h2>
        <button
          :for={{key, label} <- @tabs}
          type="button"
          phx-click="script_tab"
          phx-value-tab={key}
          class={["btn btn-xs", @tab == key && "btn-primary", @tab != key && "btn-ghost"]}
        >
          {label}
        </button>
      </div>

      <%!-- Capped and scrollable rather than as long as it likes: pinned beside
      the call, a three-thousand-pixel card would scroll the tabs off the top
      and never come back. --%>
      <div class="divide-y divide-base-300 xl:max-h-[calc(100vh-10rem)] xl:overflow-y-auto">
        <div :for={{label, body} <- @parts} class="px-5 py-4 space-y-1.5">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">{label}</p>
          <p class="text-sm leading-relaxed whitespace-pre-line">{body}</p>
        </div>

        <p :if={@parts == []} class="px-5 py-4 text-sm text-base-content/50">
          Nothing written for this one yet.
        </p>
      </div>
    </section>
    """
  end

  # One definition, used by both the log form and the edit form. Two copies
  # would drift, and the drift would be silent — a field added to one and not
  # the other simply stops being correctable after the fact.
  attr :form, :any, required: true

  defp call_debrief_fields(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="grid sm:grid-cols-2 gap-4">
        <.input field={@form[:current_software]} type="text" label="What they run now" />
        <.input
          field={@form[:category]}
          type="select"
          label="Category"
          prompt="—"
          options={Call.categories()}
        />
      </div>
      <.input
        field={@form[:what_they_like]}
        type="textarea"
        label="What they like about it"
        placeholder="The question everyone skips. It tells you what a switch must not take away."
      />
      <.input field={@form[:pain]} type="textarea" label="The exact pain" />
      <div class="grid sm:grid-cols-2 gap-4">
        <.input
          field={@form[:severity]}
          type="select"
          label="Severity"
          prompt="—"
          options={[{"1 — mentioned it", 1}, {"2", 2}, {"3", 3}, {"4", 4}, {"5 — furious", 5}]}
        />
        <.input
          field={@form[:switch_objection]}
          type="text"
          label="What would stop them switching"
        />
      </div>
    </div>
    """
  end

  defp contact_line(prospect) do
    name = Prospect.display_name(prospect)

    [name != prospect.company && name, prospect.title]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      line -> line
    end
  end

  defp where(prospect) do
    [Prospect.custom_field(prospect, "city"), Prospect.custom_field(prospect, "state")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      line -> line
    end
  end

  # Cold Forge's statuses say whether outreach should stop, which is not how a
  # person doing the calling reads them.
  defp status_label("new"), do: "Not contacted"
  defp status_label("active"), do: "In a campaign"
  defp status_label("replied"), do: "Spoke with them"
  defp status_label("bounced"), do: "Email bounced"
  defp status_label("unsubscribed"), do: "Not interested"
  defp status_label("completed"), do: "Sequence finished"
  defp status_label(other), do: other

  defp script_note(number) do
    {_, note} = Enum.find(Scripts.catalogue(), fn {n, _} -> n == number end)
    note
  end
end
