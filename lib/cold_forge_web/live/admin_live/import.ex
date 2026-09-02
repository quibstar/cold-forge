defmodule ColdForgeWeb.AdminLive.Import do
  @moduledoc """
  CSV import: upload, map columns, review, commit.

  The review step is the point of the screen. Every row is classified before
  anything is written, so you see how many are new, how many you already have,
  and how many are on the do-not-contact list *before* committing — rather than
  discovering a bought list was half-garbage after it's in the database.
  """
  use ColdForgeWeb, :live_view

  alias ColdForge.Outreach.Importer

  @max_bytes 10_000_000

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, "Import prospects")
     |> assign(:step, :upload)
     |> assign(:contents, nil)
     |> assign(:headers, [])
     |> assign(:sample_rows, [])
     |> assign(:row_count, 0)
     |> assign(:mapping, %{})
     |> assign(:analysis, nil)
     |> assign(:error, nil)
     |> allow_upload(:csv,
       accept: ~w(.csv .txt),
       max_entries: 1,
       max_file_size: @max_bytes
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket, :breadcrumbs, [
       {"Projects", ~p"/admin/projects"},
       {socket.assigns.current_project.name, ~p"/admin/p/#{socket.assigns.project_id}/prospects"}
     ])}
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    [contents] =
      consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case Importer.inspect_csv(contents) do
      {:ok, info} ->
        mapping =
          info.headers
          |> Importer.guess_mapping()
          |> Map.put(:__headers__, info.headers)

        {:noreply,
         socket
         |> assign(:contents, contents)
         |> assign(:headers, info.headers)
         |> assign(:sample_rows, info.rows)
         |> assign(:row_count, info.row_count)
         |> assign(:mapping, mapping)
         |> assign(:error, nil)
         |> assign(:step, :map)}

      {:error, :empty} ->
        {:noreply, assign(socket, :error, "That file has no rows in it.")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Couldn't read that CSV: #{reason}")}
    end
  end

  def handle_event("set_mapping", %{"field" => field, "index" => index}, socket) do
    field = String.to_existing_atom(field)

    mapping =
      case index do
        "" -> Map.delete(socket.assigns.mapping, field)
        index -> Map.put(socket.assigns.mapping, field, String.to_integer(index))
      end

    {:noreply, assign(socket, :mapping, mapping)}
  end

  def handle_event("analyze", _params, socket) do
    case Importer.analyze(
           socket.assigns.contents,
           socket.assigns.project_id,
           socket.assigns.mapping
         ) do
      {:ok, analysis} ->
        {:noreply, socket |> assign(:analysis, analysis) |> assign(:step, :review)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Couldn't read that CSV: #{reason}")}
    end
  end

  def handle_event("commit", _params, socket) do
    {:ok, result} =
      Importer.commit(socket.assigns.contents, socket.assigns.project_id, socket.assigns.mapping)

    message =
      case result do
        %{inserted: n, failed: []} -> "Imported #{n} prospects."
        %{inserted: n, failed: failed} -> "Imported #{n}. #{length(failed)} rows failed."
      end

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: ~p"/admin/p/#{socket.assigns.project_id}/prospects")}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, :step, :map)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="alert alert-error mb-4">{@error}</div>

    <.upload_step :if={@step == :upload} uploads={@uploads} />
    <.map_step
      :if={@step == :map}
      headers={@headers}
      sample_rows={@sample_rows}
      row_count={@row_count}
      mapping={@mapping}
    />
    <.review_step
      :if={@step == :review}
      analysis={@analysis}
      project_id={@project_id}
    />
    """
  end

  attr :uploads, :map, required: true

  defp upload_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <form id="csv-upload-form" phx-change="validate_upload" phx-submit="upload">
          <label
            class="flex flex-col items-center justify-center gap-2 border-2 border-dashed border-base-300 rounded-xl py-12 cursor-pointer hover:border-primary/50 transition-colors"
            phx-drop-target={@uploads.csv.ref}
          >
            <.icon name="hero-arrow-up-tray" class="size-8 text-base-content/40" />
            <span class="text-sm font-medium">Drop a CSV here, or click to choose</span>
            <span class="text-xs text-base-content/50">Up to 10 MB</span>
            <.live_file_input upload={@uploads.csv} class="sr-only" />
          </label>

          <div :for={entry <- @uploads.csv.entries} class="mt-4">
            <div class="flex items-center justify-between text-sm">
              <span class="truncate">{entry.client_name}</span>
              <span class="text-base-content/50">{entry.progress}%</span>
            </div>
            <p :for={err <- upload_errors(@uploads.csv, entry)} class="text-error text-xs mt-1">
              {error_message(err)}
            </p>
          </div>

          <button
            type="submit"
            disabled={@uploads.csv.entries == []}
            class="btn btn-primary w-full mt-4"
          >
            Continue
          </button>
        </form>

        <div class="text-xs text-base-content/50 mt-4 space-y-1">
          <p>
            The first row is treated as headers. Only an email column is required —
            everything else is optional.
          </p>
          <p>
            Columns you don't map are kept anyway, so a <code>Roof Type</code>
            column becomes <code>{"{{roof_type}}"}</code>
            in your emails.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :headers, :list, required: true
  attr :sample_rows, :list, required: true
  attr :row_count, :integer, required: true
  attr :mapping, :map, required: true

  defp map_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm mb-4">
      <div class="card-body">
        <h2 class="card-title text-base">Map the columns</h2>
        <p class="text-sm text-base-content/60">
          {@row_count} rows. We guessed from the headers — change anything that's wrong.
        </p>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 mt-3">
          <div :for={field <- Importer.fields()}>
            <label class="text-sm font-medium">
              {humanize(field)}
              <span :if={field == :email} class="text-error">*</span>
            </label>
            <select
              class="select select-bordered select-sm w-full mt-1"
              phx-change="set_mapping"
              name="index"
            >
              <input type="hidden" name="field" value={field} />
              <option value="">— not in this file —</option>
              <option
                :for={{header, index} <- Enum.with_index(@headers)}
                value={index}
                selected={@mapping[field] == index}
              >
                {header}
              </option>
            </select>
          </div>
        </div>

        <div class="mt-4 flex justify-end">
          <button
            phx-click="analyze"
            disabled={is_nil(@mapping[:email])}
            class="btn btn-primary"
          >
            Review import
          </button>
        </div>
        <p :if={is_nil(@mapping[:email])} class="text-xs text-error text-right">
          An email column is required.
        </p>
      </div>
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">First few rows</h2>
        <div class="overflow-x-auto">
          <table class="table table-xs">
            <thead>
              <tr>
                <th :for={header <- @headers}>{header}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @sample_rows}>
                <td :for={cell <- row} class="max-w-[12rem] truncate">{cell}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :analysis, :map, required: true
  attr :project_id, :string, required: true

  defp review_step(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-4 mb-4">
      <.count_card
        label="Will be added"
        value={Map.get(@analysis.counts, :new, 0)}
        tone="text-success"
      />
      <.count_card
        label="Already have"
        value={Map.get(@analysis.counts, :duplicate, 0)}
        tone="text-base-content/60"
      />
      <.count_card
        label="Do not contact"
        value={Map.get(@analysis.counts, :suppressed, 0)}
        tone="text-warning"
      />
      <.count_card
        label="Bad email"
        value={Map.get(@analysis.counts, :invalid, 0)}
        tone="text-error"
      />
    </div>

    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-base">Every row</h2>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost btn-sm">Back</button>
            <button
              phx-click="commit"
              disabled={Map.get(@analysis.counts, :new, 0) == 0}
              class="btn btn-primary btn-sm"
            >
              Import {Map.get(@analysis.counts, :new, 0)}
            </button>
          </div>
        </div>

        <div class="overflow-x-auto mt-3 max-h-[32rem]">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Email</th>
                <th>Name</th>
                <th>Company</th>
                <th>Outcome</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @analysis.rows}>
                <td class="font-mono text-xs">{row.email}</td>
                <td class="text-sm">
                  {[row.attrs[:first_name], row.attrs[:last_name]]
                  |> Enum.reject(&is_nil/1)
                  |> Enum.join(" ")}
                </td>
                <td class="text-sm">{row.attrs[:company]}</td>
                <td>
                  <span class={["badge badge-sm", status_class(row.status)]}>{row.status}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp count_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body py-4 items-center">
        <div class={["text-2xl font-bold tabular-nums", @tone]}>{@value}</div>
        <div class="text-xs text-base-content/50">{@label}</div>
      </div>
    </div>
    """
  end

  defp status_class(:new), do: "badge-success"
  defp status_class(:duplicate), do: "badge-ghost"
  defp status_class(:suppressed), do: "badge-warning"
  defp status_class(:invalid), do: "badge-error"

  defp humanize(field) do
    field |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp error_message(:too_large), do: "That file is over 10 MB."
  defp error_message(:not_accepted), do: "That doesn't look like a CSV."
  defp error_message(:too_many_files), do: "One file at a time."
  defp error_message(error), do: to_string(error)
end
