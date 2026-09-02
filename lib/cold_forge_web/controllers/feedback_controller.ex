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
    with true <- ColdForgeWeb.WebhookAuth.authorized?(token),
         verdict when verdict in [:ok, :not_signed] <- SNS.Signature.verify(params) do
      handle(SNS.unwrap(params), conn)
    else
      false ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        Logger.warning("rejected SNS feedback payload: #{inspect(reason)}")
        conn |> put_status(:forbidden) |> json(%{error: "bad signature"})
    end
  end

  # Confirmed here rather than by hand in the console — the signature check
  # above has already proved the body is Amazon's. An unconfirmed subscription
  # looks exactly like a working one until the bounces it should have caught
  # have already counted against the account.
  defp handle({:confirmation, url, topic_arn}, conn) do
    case SNS.confirm(url, topic_arn) do
      :ok ->
        Logger.info("confirmed SNS feedback subscription on #{topic_arn}")
        json(conn, %{status: "confirmed"})

      {:error, reason} ->
        Logger.warning("could not confirm SNS subscription (#{inspect(reason)}): #{url}")
        json(conn, %{status: "confirmation_pending"})
    end
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
