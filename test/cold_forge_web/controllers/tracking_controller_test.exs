defmodule ColdForgeWeb.TrackingControllerTest do
  @moduledoc """
  These endpoints are the only part of Cold Forge exposed to the open internet.
  The cases that matter are the hostile ones: bad tokens, and mail clients that
  prefetch links.
  """
  use ColdForgeWeb.ConnCase, async: true

  alias ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Outreach, Sending}

  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step = step_fixture(campaign)
    prospect = prospect_fixture(project)

    {:ok, message} = Sending.deliver_step(prospect, step, project)
    [link] = Outreach.get_message!(message.id).tracked_links

    %{project: project, prospect: prospect, message: message, link: link}
  end

  describe "GET /c/:token" do
    test "redirects to the destination with attribution", %{conn: conn, link: link} do
      conn = get(conn, ~p"/c/#{link.token}")

      assert redirected_to(conn) == "https://exteriorpro.io/demo?cf=#{link.token}"
      assert Repo.reload(link).click_count == 1
    end

    test "an unknown token lands somewhere sensible rather than erroring", %{conn: conn} do
      conn = get(conn, ~p"/c/made-up-token")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "GET /o/:token" do
    test "returns a pixel and records the open", %{conn: conn, message: message} do
      conn = get(conn, ~p"/o/#{message.open_token <> ".png"}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/gif"]
      # Cached pixels would swallow every open after the first.
      assert get_resp_header(conn, "cache-control") |> hd() =~ "no-store"
      assert Repo.reload(message).open_count == 1
    end

    test "still returns an image for an unknown token", %{conn: conn} do
      conn = get(conn, ~p"/o/nonsense.png")
      assert response(conn, 200)
    end
  end

  describe "unsubscribe" do
    test "GET shows a confirmation and does NOT unsubscribe", %{conn: conn, prospect: prospect} do
      conn = get(conn, ~p"/u/#{prospect.unsubscribe_token}")

      assert html_response(conn, 200) =~ "Unsubscribe"
      # Mail clients prefetch links to scan them. A GET that opted people out
      # would unsubscribe recipients who never clicked anything.
      assert Repo.reload(prospect).status == "new"
    end

    test "POST unsubscribes and suppresses globally", %{conn: conn, prospect: prospect} do
      conn = post(conn, ~p"/u/#{prospect.unsubscribe_token}")

      assert html_response(conn, 200) =~ "unsubscribed"
      assert Repo.reload(prospect).status == "unsubscribed"
      assert Outreach.suppressed?(prospect.email)
    end

    test "POST needs no CSRF token, so RFC 8058 one-click works", %{prospect: prospect} do
      # A bare conn with no session — what a mail client sends.
      conn = Phoenix.ConnTest.build_conn() |> post(~p"/u/#{prospect.unsubscribe_token}")

      assert html_response(conn, 200) =~ "unsubscribed"
      assert Repo.reload(prospect).status == "unsubscribed"
    end

    test "an unknown token explains itself instead of 500ing", %{conn: conn} do
      conn = get(conn, ~p"/u/not-a-token")
      assert html_response(conn, 200) =~ "isn't valid"
    end
  end
end
