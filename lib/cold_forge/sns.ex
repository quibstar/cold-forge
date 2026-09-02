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
    * `{:confirmation, url, topic_arn}` — a new subscription to confirm
    * `{:unsubscribe_confirmation, url}` — the subscription is being torn down
    * `{:raw, params}` — not SNS at all; some other provider's own shape

  A `"Message"` that is not JSON comes back as `%{"content" => message}`, since
  SES email receiving can deliver a raw MIME string rather than an object.
  """
  def unwrap(%{"Type" => "Notification"} = params) do
    {:notification, decode_message(params["Message"])}
  end

  def unwrap(%{"Type" => "SubscriptionConfirmation"} = params) do
    {:confirmation, params["SubscribeURL"], params["TopicArn"]}
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

  @doc """
  Completes a subscription by fetching the `SubscribeURL` SNS sent.

  Only ever called after `ColdForge.SNS.Signature.verify/1` has proved the body
  is Amazon's, because this follows a URL taken out of a request body. The host
  is checked again here regardless: two cheap checks are worth less than one
  request-forgery bug.

  Doing this in the app rather than by hand in the console is the difference
  between a subscription that works the moment it is created and one that sits
  in `PendingConfirmation` until somebody remembers. A subscription that is
  never confirmed looks exactly like one that works — until the bounces it was
  supposed to catch have already counted against the account.
  """
  def confirm(url, topic_arn) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" or
          not Regex.match?(~r/^sns\.[a-z0-9\-]+\.amazonaws\.com(\.cn)?$/, uri.host || "") ->
        {:error, :bad_subscribe_url}

      not allowed?(topic_arn) ->
        {:error, :topic_not_allowed}

      true ->
        case Req.get(url, receive_timeout: 10_000, retry: false) do
          {:ok, %{status: 200}} -> :ok
          other -> {:error, {:confirm_failed, inspect(other)}}
        end
    end
  end

  def confirm(_url, _topic_arn), do: {:error, :bad_subscribe_url}

  # An optional allowlist. Left unset, any topic whose signature checks out is
  # accepted — reaching this point already required the URL secret *and* a valid
  # Amazon signature. Set it to pin the exact topics once they exist.
  defp allowed?(topic_arn) do
    case Application.get_env(:cold_forge, :sns_topic_arns) do
      nil -> true
      [] -> true
      allowed when is_list(allowed) -> topic_arn in allowed
    end
  end
end
