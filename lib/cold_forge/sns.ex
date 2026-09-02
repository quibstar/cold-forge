defmodule ColdForge.SNS do
  @moduledoc """
  Unwraps Amazon SNS's envelope.

  SNS does not POST the payload you subscribed for. It POSTs its own JSON
  object with the real payload as a *string* under `"Message"`, which has to be
  decoded again. Reading `params["mail"]` straight off an SNS delivery finds
  nothing, and the failure is silent: every field comes back `nil` and the
  handler decides, reasonably, that it has nothing to record.

  Providers that POST their payload directly — Mailgun, Postmark, SendGrid —
  have no envelope, so `:raw` passes them through untouched and the handlers
  stay provider-agnostic.
  """

  @doc """
  Classifies an SNS POST body.

    * `{:notification, payload}` — the decoded inner message
    * `{:confirmation, url}` — a new subscription waiting to be confirmed
    * `{:unsubscribe_confirmation, url}` — the subscription is being torn down
    * `{:raw, params}` — not SNS at all; some other provider's own shape

  A `"Message"` that is not JSON comes back as `%{"content" => message}`, since
  SES email receiving can deliver a raw MIME string rather than an object.
  """
  def unwrap(%{"Type" => "Notification"} = params) do
    {:notification, decode_message(params["Message"])}
  end

  def unwrap(%{"Type" => "SubscriptionConfirmation"} = params) do
    {:confirmation, params["SubscribeURL"]}
  end

  def unwrap(%{"Type" => "UnsubscribeConfirmation"} = params) do
    {:unsubscribe_confirmation, params["SubscribeURL"]}
  end

  def unwrap(params), do: {:raw, params}

  defp decode_message(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{} = payload} -> payload
      _ -> %{"content" => message}
    end
  end

  defp decode_message(%{} = message), do: message
  defp decode_message(_), do: %{}
end
