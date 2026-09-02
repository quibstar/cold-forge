defmodule ColdForgeWeb.TrackingController do
  @moduledoc """
  The three endpoints that appear in outgoing mail.

  All of them are hit by strangers and by bots, so every action tolerates an
  unknown or malformed token without raising. None of them expose anything
  about a prospect: the token is the only identifier, and it maps to a row
  rather than encoding one.
  """

  use ColdForgeWeb, :controller

  alias ColdForge.{Outreach, Tracking}

  # A 1x1 transparent GIF, served for the open pixel. Inlined rather than read
  # from priv so the response never touches the filesystem.
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  @doc """
  `/c/:token` — records the click, then redirects out to the project's landing
  page with a `cf` attribution parameter.

  An unknown token still has to go somewhere sensible: a recipient clicking a
  link from a message we've since deleted should not see an error page.
  """
  def click(conn, %{"token" => token}) do
    case Tracking.get_tracked_link(token) do
      nil ->
        redirect(conn, to: ~p"/")

      link ->
        destination =
          Tracking.record_click(link, %{
            ip: client_ip(conn),
            user_agent: user_agent(conn)
          })

        redirect(conn, external: destination)
    end
  end

  @doc "`/o/:token.png` — the open pixel. Always returns an image, token or not."
  def open(conn, %{"token" => token}) do
    token |> String.replace_suffix(".png", "") |> Tracking.record_open()

    conn
    |> put_resp_content_type("image/gif", nil)
    # Proxies caching the pixel would swallow every open after the first.
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
    |> send_resp(200, @pixel)
  end

  @doc """
  `GET /u/:token` — the unsubscribe confirmation page.

  Deliberately does *not* unsubscribe on GET. Gmail and Outlook prefetch links
  in mail to scan them; a GET that mutated would opt people out who never
  clicked anything.
  """
  def unsubscribe_form(conn, %{"token" => token}) do
    case Outreach.get_prospect_by_unsubscribe_token(token) do
      nil ->
        render(conn, :unsubscribe_invalid, layout: false, page_title: "Unsubscribe")

      %{status: "unsubscribed"} = prospect ->
        render(conn, :unsubscribe_done,
          layout: false,
          page_title: "Unsubscribed",
          email: prospect.email
        )

      prospect ->
        render(conn, :unsubscribe_form,
          layout: false,
          page_title: "Unsubscribe",
          token: token,
          email: prospect.email
        )
    end
  end

  @doc """
  `POST /u/:token` — performs the unsubscribe.

  Also serves RFC 8058 one-click unsubscribe, which mail clients POST here
  directly from their own UI. Those requests carry no CSRF token, which is why
  this route sits outside the protected browser pipeline.
  """
  def unsubscribe(conn, %{"token" => token}) do
    case Outreach.get_prospect_by_unsubscribe_token(token) do
      nil ->
        render(conn, :unsubscribe_invalid, layout: false, page_title: "Unsubscribe")

      prospect ->
        {:ok, prospect} = Outreach.unsubscribe_prospect(prospect)

        render(conn, :unsubscribe_done,
          layout: false,
          page_title: "Unsubscribed",
          email: prospect.email
        )
    end
  end

  # Behind a load balancer the peer address is the balancer, so a forwarded
  # header wins when present.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [value | _] -> String.slice(value, 0, 500)
      [] -> nil
    end
  end
end
