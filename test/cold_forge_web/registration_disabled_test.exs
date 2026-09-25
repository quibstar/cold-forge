defmodule ColdForgeWeb.RegistrationDisabledTest do
  @moduledoc """
  There is no signup. This app is served from the same public hostname as the
  tracked links, unsubscribe pages and surveys that strangers click, so an open
  registration form would let anyone who finds it create an admin account able
  to read every prospect and send mail as the project's from-address.

  Operator accounts are made from the console with
  `ColdForge.Accounts.register_user/1`, which stays — it is how the first
  account on a new deploy exists at all.
  """
  use ColdForgeWeb.ConnCase, async: true

  test "there is no registration page", %{conn: conn} do
    assert conn |> get("/users/register") |> response(404)
  end

  test "the log-in page doesn't offer one", %{conn: conn} do
    html = conn |> get(~p"/users/log-in") |> html_response(200)

    refute html =~ "/users/register"
    refute html =~ "Sign up"
  end

  test "accounts can still be created from the console" do
    assert {:ok, user} = ColdForge.Accounts.register_user(%{email: "operator@example.com"})
    assert user.email == "operator@example.com"
  end
end
