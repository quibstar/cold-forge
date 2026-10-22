defmodule ColdForgeWeb.AdminLive.Scripts do
  @moduledoc """
  The project's scripts: add, edit, reorder, throw out. Each is a tab on the
  call page, in this order — voicemails included, as a script of their own.

  The placeholder list is on this screen rather than in a help page because the
  question is never "does `{{city}}` exist" — it is "what does it say when I
  read it out", and the answer is right there against a real prospect.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Calling.Scripts
  alias ColdForge.Outreach
  alias ColdForge.Outreach.{CallScript, Prospect}

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, "Scripts")
     |> assign(:page_subtitle, "What to say, written once and read with their details in it.")
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
     |> assign(:editing, nil)
     |> assign(:form, nil)
     |> load()}
  end

  defp load(socket) do
    project = socket.assigns.current_project
    sample = project.id |> Outreach.list_prospects() |> List.last()

    socket
    |> assign(:scripts, Outreach.list_call_scripts(project.id, "script"))
    |> assign(:sample, sample)
    |> assign(:blanks, blanks(sample, project))
  end

  # Which tags come back empty for a real prospect off this project. The sample
  # rather than all of them: this is a hint on a form, not an audit, and one
  # row answers "is this field filled in round here" well enough.
  defp blanks(sample, project) do
    for {name, value} <- placeholders(sample, project), value in [nil, ""], do: name
  end

  @impl true
  def handle_event("new", _params, socket) do
    script = %CallScript{project_id: socket.assigns.project_id}

    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(:form, to_form(Outreach.change_call_script(script), id: "script-form"))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    script = Outreach.get_call_script!(id)

    {:noreply,
     socket
     |> assign(:editing, script)
     |> assign(:form, to_form(Outreach.change_call_script(script), id: "script-form"))}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: nil)}

  def handle_event("validate", %{"call_script" => params}, socket) do
    script = if socket.assigns.editing == :new, do: %CallScript{}, else: socket.assigns.editing

    changeset =
      script |> Outreach.change_call_script(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, id: "script-form"))}
  end

  def handle_event("save", %{"call_script" => params}, socket) do
    params = Map.put(params, "project_id", socket.assigns.project_id)

    result =
      case socket.assigns.editing do
        :new -> Outreach.create_call_script(params)
        script -> Outreach.update_call_script(script, params)
      end

    case result do
      {:ok, script} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{script.name} saved.")
         |> assign(editing: nil, form: nil)
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, id: "script-form"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    script = Outreach.get_call_script!(id)
    {:ok, _} = Outreach.delete_call_script(script)

    {:noreply,
     socket
     |> put_flash(:info, "#{script.name} deleted.")
     |> assign(editing: nil, form: nil)
     |> load()}
  end

  # Swapping the two positions rather than renumbering the list, so a move
  # touches the two rows it's about and nothing else.
  def handle_event("move", %{"id" => id, "by" => by}, socket) do
    script = Outreach.get_call_script!(id)
    list = Outreach.list_call_scripts(script.project_id)
    index = Enum.find_index(list, &(&1.id == script.id))

    case Enum.at(list, index + String.to_integer(by)) do
      nil ->
        {:noreply, socket}

      neighbour ->
        swap(script, neighbour, list)
        {:noreply, load(socket)}
    end
  end

  def handle_event("add_voicemails", _params, socket) do
    {:ok, _} =
      Scripts.voicemails()
      |> Map.put(:project_id, socket.assigns.project_id)
      |> Outreach.create_call_script()

    {:noreply, socket |> put_flash(:info, "Voicemails added.") |> load()}
  end

  # Two at once would collide on the unique index, so the first parks in a free
  # slot above everything before the second takes its number. Parking above
  # rather than below zero because a position has to stay positive.
  defp swap(a, b, list) do
    parking = (list |> Enum.map(& &1.position) |> Enum.max()) + 1

    ColdForge.Repo.transaction(fn ->
      {:ok, _} = Outreach.update_call_script(a, %{"position" => parking})
      {:ok, _} = Outreach.update_call_script(b, %{"position" => a.position})
      {:ok, _} = Outreach.update_call_script(a, %{"position" => b.position})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div class="grid gap-4 lg:grid-cols-3">
      <div class="lg:col-span-2 space-y-4">
        <.script_list
          kind="script"
          title="Scripts"
          blurb="One per tab on the call screen, in this order."
          scripts={@scripts}
          editing={@editing}
          form={@form}
          blanks={@blanks}
        >
          <button
            :if={not Enum.any?(@scripts, &(&1.name == Scripts.voicemails_name()))}
            id="add-voicemails"
            phx-click="add_voicemails"
            class="btn btn-sm btn-ghost self-start"
          >
            <.icon name="hero-plus" class="size-4" /> Add the four starter voicemails
          </button>
        </.script_list>
      </div>

      <div class="card bg-base-100 shadow-sm h-fit lg:sticky lg:top-20">
        <div class="card-body">
          <h2 class="card-title text-base">Placeholders</h2>
          <p class="text-xs text-base-content/50">
            <span :if={@sample}>Filled in for {Prospect.display_name(@sample)}.</span>
            Always give one a fallback after a pipe —
            <code class="text-primary">{"{{industry|exterior}}"}</code>
            reads "exterior" when the field is empty, where <code>{"{{industry}}"}</code>
            leaves a hole in a sentence you are reading out loud.
          </p>

          <dl class="mt-2 space-y-1 text-xs">
            <div
              :for={{name, value} <- placeholders(@sample, @current_project)}
              class="flex items-baseline justify-between gap-3"
            >
              <dt class="font-mono text-primary shrink-0">{"{{#{name}}}"}</dt>
              <dd class={[
                "truncate text-right",
                if(value in [nil, ""], do: "text-base-content/30", else: "text-base-content/70")
              ]}>
                {if value in [nil, ""], do: "— not set —", else: value}
              </dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true
  attr :scripts, :list, required: true
  attr :editing, :any, default: nil
  attr :form, :any, default: nil
  attr :blanks, :list, default: []
  slot :inner_block

  defp script_list(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="card-title text-base">
              {@title} <span class="badge badge-sm badge-ghost">{length(@scripts)}</span>
            </h2>
            <p class="text-xs text-base-content/50">{@blurb}</p>
          </div>
          <button phx-click="new" class="btn btn-sm btn-primary shrink-0">
            Add
          </button>
        </div>

        {render_slot(@inner_block)}

        <p :if={@scripts == []} class="text-sm text-base-content/50">
          Nothing written yet.
        </p>

        <ul class="divide-y divide-base-200">
          <li :for={{script, index} <- Enum.with_index(@scripts)} class="py-3">
            <.script_form
              :if={is_struct(@editing, CallScript) && @editing.id == script.id}
              form={@form}
              kind={@kind}
            />

            <div :if={!(is_struct(@editing, CallScript) && @editing.id == script.id)}>
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="font-medium truncate">
                    <span class="text-base-content/40 tabular-nums mr-1">{script.position}</span>
                    {script.name}
                  </p>
                  <p class="text-xs text-base-content/50 line-clamp-2 whitespace-pre-line">
                    {script.body}
                  </p>
                  <%!-- Only the tags that are *both* without a fallback and
                  empty on a real prospect. Flagging every tag without one
                  would mark `{{company}}` on every script, which is a badge
                  nobody reads twice; this marks the ones that would actually
                  render as a hole mid-sentence. --%>
                  <p :if={risky_tags(script, @blanks) != []} class="text-xs mt-1">
                    <span class="badge badge-xs badge-warning">renders blank</span>
                    <span class="text-base-content/50 ml-1 font-mono">
                      {Enum.map_join(risky_tags(script, @blanks), " ", &"{{#{&1}}}")}
                    </span>
                  </p>
                </div>

                <div class="flex items-center gap-1 shrink-0">
                  <button
                    phx-click="move"
                    phx-value-id={script.id}
                    phx-value-by="-1"
                    disabled={index == 0}
                    class="btn btn-xs btn-ghost"
                    aria-label="Move up"
                  >
                    <.icon name="hero-arrow-up" class="size-3.5" />
                  </button>
                  <button
                    phx-click="move"
                    phx-value-id={script.id}
                    phx-value-by="1"
                    disabled={index == length(@scripts) - 1}
                    class="btn btn-xs btn-ghost"
                    aria-label="Move down"
                  >
                    <.icon name="hero-arrow-down" class="size-3.5" />
                  </button>
                  <button phx-click="edit" phx-value-id={script.id} class="btn btn-xs btn-ghost">
                    Edit
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={script.id}
                    data-confirm={"Delete #{script.name}? The words are gone; calls that recorded it keep their record."}
                    class="btn btn-xs btn-ghost text-error"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </li>
        </ul>

        <.script_form :if={@editing == :new} form={@form} kind={@kind} />
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :kind, :string, required: true

  defp script_form(assigns) do
    ~H"""
    <.form for={@form} id="script-form" phx-change="validate" phx-submit="save" class="space-y-3">
      <input type="hidden" name="call_script[kind]" value={@kind} />

      <div class="grid gap-3 sm:grid-cols-4">
        <div class="sm:col-span-3">
          <.input field={@form[:name]} label="Name" placeholder="Script 1" />
        </div>
        <.input field={@form[:position]} type="number" label="Order" />
      </div>

      <.input
        field={@form[:body]}
        type="textarea"
        rows="14"
        label="What to say"
        placeholder="Hi — is this {{company}}?"
      />

      <div class="flex items-center gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">Cancel</button>
      </div>
    </.form>
    """
  end

  # A tag with no fallback is only a problem when the field behind it is empty:
  # `{{company}}` without one is fine on a list where every row has a company.
  defp risky_tags(script, blanks) do
    script |> CallScript.tags_without_fallback() |> Enum.filter(&(&1 in blanks))
  end

  # A prospect's own tags plus the four the project supplies. Without a
  # prospect to read against, the names are still worth showing.
  defp placeholders(sample, project) do
    prospect_tags =
      case sample do
        %Prospect{} = prospect ->
          Prospect.merge_values(prospect)

        _ ->
          Enum.map(
            ~w(first_name last_name full_name email company title industry phone website),
            &{&1, nil}
          )
      end

    prospect_tags ++
      [
        {"callback", project.phone},
        {"sender_name", project.from_name},
        {"project", project.name},
        {"link", project.landing_url}
      ]
  end
end
