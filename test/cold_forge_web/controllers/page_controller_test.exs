defmodule ColdForgeWeb.PageControllerTest do
  use ColdForgeWeb.ConnCase, async: true

  import ColdForge.AccountsFixtures

  test "GET / sends anonymous visitors to the log-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / sends the operator to the admin", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/admin"
  end
end
