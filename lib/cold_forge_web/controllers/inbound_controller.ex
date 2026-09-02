defmodule ColdForgeWeb.InboundController do
  @moduledoc """
  Where replies arrive.

  Deliberately provider-shaped rather than provider-specific: SES-via-SNS,
  Mailgun, Postmark and SendGrid all POST a JSON body with the same handful of
  facts under different names, so the parsing normalises them and the matching
  never learns which one it is talking to.

  Authenticated by a shared secret in the URL rather than a session — the caller
  is a machine with no cookie. Without a configured secret the endpoint refuses
  everything, so a deploy that forgets to set one fails closed rather than
  accepting mail from anyone who finds the path.
  """
  use ColdForgeWeb, :controller

  require Logger

  alias ColdForge.Inbox

  def create(conn, %{"token" => token} = params) do
    if authorized?(token) do
      params |> parse() |> handle(conn)
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp handle(email, conn) do
    case Inbox.receive_email(email) do
      {:ok, :duplicate} ->
        json(conn, %{status: "duplicate"})

      {:ok, reply} ->
        json(conn, %{status: "recorded", matched_by: reply.matched_by})

      {:error, :no_match} ->
        # Mail from somebody we have never written to. Routine at a public
        # address, and a 200 keeps the provider from retrying it forever.
        json(conn, %{status: "ignored"})

      {:error, reason} ->
        Logger.error("inbound reply failed: #{inspect(reason)}")
        conn |> put_status(:unprocessable_entity) |> json(%{error: "could not record"})
    end
  end

  # A constant-time compare, because a shared secret checked with `==` leaks its
  # length and prefix to anyone willing to time the responses.
  defp authorized?(token) do
    case Application.get_env(:cold_forge, :inbound_token) do
      secret when is_binary(secret) and secret != "" ->
        Plug.Crypto.secure_compare(token, secret)

      _ ->
        false
    end
  end

  @doc """
  Normalises a provider's payload into what `ColdForge.Inbox` expects.

  Each provider spells the same fields differently; SES wraps them a layer
  deeper again, under an SNS envelope.
  """
  def parse(params) do
    mail = params["mail"] || params

    %{
      from: first_present([params["from"], params["sender"], params["From"], mail["source"]]),
      subject:
        first_present([
          params["subject"],
          params["Subject"],
          get_in(mail, ["commonHeaders", "subject"])
        ]),
      body:
        first_present([
          params["text"],
          params["body-plain"],
          params["TextBody"],
          params["stripped-text"],
          params["content"]
        ]),
      in_reply_to:
        first_present([
          params["in_reply_to"],
          params["In-Reply-To"],
          get_in(params, ["headers", "In-Reply-To"]),
          header(mail, "in-reply-to")
        ]),
      references:
        first_present([
          params["references"],
          params["References"],
          get_in(params, ["headers", "References"]),
          header(mail, "references")
        ]),
      headers: params["headers"] || headers_map(mail),
      external_id:
        first_present([
          params["external_id"],
          params["MessageID"],
          params["message-id"],
          mail["messageId"]
        ]),
      received_at:
        parse_time(first_present([params["received_at"], params["Date"], mail["timestamp"]]))
    }
  end

  # SES delivers headers as a list of name/value maps rather than an object.
  defp headers_map(%{"headers" => headers}) when is_list(headers) do
    Map.new(headers, fn h -> {String.downcase(h["name"] || ""), h["value"]} end)
  end

  defp headers_map(_), do: %{}

  defp header(mail, name) do
    mail |> headers_map() |> Map.get(name)
  end

  defp first_present(values) do
    Enum.find(values, fn v -> is_binary(v) and String.trim(v) != "" end)
  end

  # An unparseable date is not worth rejecting a reply over; "now" is close
  # enough for something that just arrived.
  defp parse_time(nil), do: DateTime.utc_now()

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
