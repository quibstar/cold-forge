defmodule ColdForgeWeb.AdminLive.Nav do
  @moduledoc """
  Keeps the admin layout's sidebar in sync with wherever you are.

  The layout needs `current_path` (to highlight a nav item) and
  `current_project` (to decide whether the per-project section exists at all).
  Neither is derivable from the socket alone, so this runs `on_mount` for every
  admin LiveView instead of being repeated in each one.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias ColdForge.Outreach

  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign_current_project(params)
      |> Phoenix.Component.assign_new(:breadcrumbs, fn -> [] end)
      |> attach_hook(:track_path, :handle_params, &track_path/3)

    {:cont, socket}
  end

  # `:project_id` is in the route for every project-scoped page, so the sidebar
  # section follows the URL rather than a stored selection that could go stale.
  defp assign_current_project(socket, %{"project_id" => project_id}) do
    assign(socket, :current_project, Outreach.get_project!(project_id))
  end

  defp assign_current_project(socket, _params), do: assign(socket, :current_project, nil)

  defp track_path(_params, uri, socket) do
    {:cont, assign(socket, :current_path, URI.parse(uri).path)}
  end
end
