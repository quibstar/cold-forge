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

  alias ColdForge.{Markets, Outreach}
  alias ColdForge.Markets.Market

  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign_current_project(params)
      |> assign_current_market(params)
      |> Phoenix.Component.assign_new(:breadcrumbs, fn -> [] end)
      |> attach_hook(:track_path, :handle_params, &track_path/3)

    {:cont, socket}
  end

  # `:project_id` is in the route for every project-scoped page, so the sidebar
  # section follows the URL rather than a stored selection that could go stale.
  defp assign_current_project(socket, %{"project_id" => project_id}) do
    socket
    |> assign(:current_project, Outreach.get_project!(project_id))
    # Listed under the project in the sidebar. Read on mount, which every
    # create, rename and delete ends in, so the list can't go stale.
    |> assign(:current_project_markets, Markets.list_markets(project_id))
  end

  defp assign_current_project(socket, _params), do: assign(socket, :current_project, nil)

  # Inside a campaign the URL carries `:market_id`, and every list narrows to
  # its people. `base` is the prefix the working screens' links are built on —
  # the project's or the campaign's — so a link from a campaign's call list
  # opens that call inside the campaign rather than dropping you back out.
  defp assign_current_market(socket, %{"project_id" => project_id, "market_id" => market_id}) do
    market = Markets.get_market!(market_id)

    # A campaign from another project under this one's URL would show that
    # project's people under this one's name.
    if market.project_id != project_id, do: raise(Ecto.NoResultsError, queryable: Market)

    socket
    |> assign(:current_market, market)
    |> assign(:market_id, market.id)
    |> assign(:base, "/admin/p/#{project_id}/c/#{market.id}")
  end

  defp assign_current_market(socket, %{"project_id" => project_id}) do
    socket
    |> assign(:current_market, nil)
    |> assign(:market_id, nil)
    |> assign(:base, "/admin/p/#{project_id}")
  end

  defp assign_current_market(socket, _params),
    do: socket |> assign(:current_market, nil) |> assign(:market_id, nil)

  defp track_path(_params, uri, socket) do
    {:cont, assign(socket, :current_path, URI.parse(uri).path)}
  end
end
