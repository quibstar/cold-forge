defmodule ColdForgeWeb.ObanDashboardTest do
  @moduledoc """
  Oban's dashboard can cancel and delete any job, so it sits behind the same
  login as the rest of the admin.
  """
  use ColdForgeWeb.ConnCase, async: true

  test "needs a login", %{conn: conn} do
    conn = get(conn, "/admin/oban")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
