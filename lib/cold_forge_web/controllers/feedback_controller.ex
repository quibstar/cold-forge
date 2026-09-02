defmodule ColdForgeWeb.FeedbackController do
  @moduledoc """
  Where SES reports bounces and complaints, over SNS.

  Separate from `/inbound` so the two SNS topics cannot be pointed at each
  other's endpoint — the consoles list them side by side, and a reply topic
  delivering into the suppression path is not a mistake you would notice
  quickly.

  Authenticated by the same shared secret in the URL, for the same reason: the
  caller is a machine with no cookie, and without a configured secret this
  refuses everything rather than accepting whatever finds the path.
  """
  use ColdForgeWeb, :controller

  require Logger

  alias ColdForge.{Feedback, SNS}

  def create(conn, %{"token" => token} = params) do
    if ColdForgeWeb.WebhookAuth.authorized?(token) do
      handle(SNS.unwrap(params), conn)
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp handle({:confirmation, url}, conn) do
    # Logged, never fetched. Confirming a subscription by following a URL out of
    # the request body would let anyone holding the token point this endpoint at
    # a topic of their choosing; a human confirms it in the SNS console.
    Logger.info("SNS subscription confirmation received — confirm in the console: #{url}")
    json(conn, %{status: "confirmation_pending"})
  end

  defp handle({:unsubscribe_confirmation, _url}, conn) do
    Logger.warning("SNS unsubscribe confirmation — feedback notifications have been detached")
    json(conn, %{status: "ok"})
  end

  defp handle({kind, payload}, conn) when kind in [:notification, :raw] do
    {:ok, summary} = Feedback.record(payload)

    if summary[:action] == :suppressed do
      Logger.info("#{summary.reason}: suppressed #{Enum.join(summary.emails, ", ")}")
    end

    json(conn, %{status: to_string(summary.action)})
  end
end
