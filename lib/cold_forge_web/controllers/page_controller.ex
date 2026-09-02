defmodule ColdForgeWeb.PageController do
  use ColdForgeWeb, :controller

  @doc """
  Cold Forge has no public front page — the admin *is* the application.

  Signed in, `/` goes to the dashboard; signed out, to the login. This also
  catches recipients who click a tracked link whose message has since been
  deleted, which is why it never renders anything of its own.
  """
  def home(conn, _params) do
    case conn.assigns[:current_scope] do
      %{user: %{}} -> redirect(conn, to: ~p"/admin")
      _ -> redirect(conn, to: ~p"/users/log-in")
    end
  end
end
