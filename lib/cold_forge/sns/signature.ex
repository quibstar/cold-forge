defmodule ColdForge.SNS.Signature do
  @moduledoc """
  Proves an SNS POST really came from Amazon.

  This is what lets the app confirm its own subscriptions. Confirming means
  following a URL out of a request body, which is only safe if the body is
  provably Amazon's — otherwise anyone reaching the endpoint could aim it at a
  topic of their choosing.

  SNS signs a canonical rendering of specific fields, in a fixed order, with a
  certificate it publishes. Verifying means rebuilding that exact string,
  fetching the certificate, and checking the signature against it.

  Two details are load-bearing:

    * **The certificate URL is attacker-supplied**, so it is checked against
      Amazon's hostname before anything fetches it. Skipping that turns
      signature verification into a request-forgery gadget aimed at whatever
      the caller names.
    * **The signed field list differs by message type.** A confirmation signs
      `SubscribeURL` and `Token`; a notification does not. Using the wrong set
      produces a mismatch indistinguishable from tampering.
  """

  require Logger
  require Record

  # X.509 structures come back from :public_key as Erlang records — nested
  # tuples, not maps — so they are extracted by name rather than navigated by
  # position, which would silently break if OTP reordered a field.
  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  # Only Amazon's own SNS endpoints, and only over TLS.
  @cert_host ~r/^sns\.[a-z0-9\-]+\.amazonaws\.com(\.cn)?$/

  # The fields SNS signs, in the order it signs them.
  @notification_fields ~w(Message MessageId Subject Timestamp TopicArn Type)
  @confirmation_fields ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)

  @doc """
  Verifies an SNS message signature.

  Returns `:not_signed` for a payload carrying no signature at all — a direct
  POST from some other provider, which the URL secret alone guards. A message
  that *claims* to be signed is always held to it.
  """
  def verify(%{"Signature" => signature, "SigningCertURL" => cert_url} = params)
      when is_binary(signature) and is_binary(cert_url) do
    with {:ok, url} <- validate_cert_url(cert_url),
         {:ok, public_key} <- fetch_public_key(url),
         {:ok, decoded} <- decode(signature) do
      if :public_key.verify(string_to_sign(params), digest(params), decoded, public_key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  def verify(_params), do: :not_signed

  @doc """
  Rebuilds the exact string SNS signed: each field name and value, newline
  separated, in Amazon's order. An absent optional field (`Subject`) is skipped
  rather than sent empty.
  """
  def string_to_sign(params) do
    fields =
      case params["Type"] do
        "Notification" -> @notification_fields
        _ -> @confirmation_fields
      end

    fields
    |> Enum.filter(&is_binary(params[&1]))
    |> Enum.map_join(fn field -> "#{field}\n#{params[field]}\n" end)
  end

  # SignatureVersion 1 is SHA-1, 2 is SHA-256. Amazon still sends 1 on older
  # topics, so both have to work.
  defp digest(%{"SignatureVersion" => "2"}), do: :sha256
  defp digest(_), do: :sha

  defp validate_cert_url(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and Regex.match?(@cert_host, uri.host) do
      {:ok, url}
    else
      Logger.warning("refused SNS signing certificate from #{inspect(url)}")
      {:error, :bad_cert_url}
    end
  end

  defp decode(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :bad_signature_encoding}
    end
  end

  # Certificates are public and change rarely, so one fetch per URL for the life
  # of the node is plenty.
  defp fetch_public_key(url) do
    case :persistent_term.get({__MODULE__, url}, nil) do
      nil ->
        with {:ok, pem} <- fetch(url), {:ok, key} <- public_key(pem) do
          :persistent_term.put({__MODULE__, url}, key)
          {:ok, key}
        end

      key ->
        {:ok, key}
    end
  end

  defp fetch(url) do
    case Application.get_env(:cold_forge, :sns_cert_fetcher) do
      nil ->
        case Req.get(url, receive_timeout: 5_000, retry: false) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          other -> {:error, {:cert_fetch_failed, inspect(other)}}
        end

      fun when is_function(fun, 1) ->
        fun.(url)
    end
  end

  defp public_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        key =
          der
          |> :public_key.pkix_decode_cert(:otp)
          |> otp_certificate(:tbsCertificate)
          |> otp_tbs_certificate(:subjectPublicKeyInfo)
          |> otp_subject_public_key_info(:subjectPublicKey)

        {:ok, key}

      _ ->
        {:error, :bad_certificate}
    end
  rescue
    _ -> {:error, :bad_certificate}
  end

  defp public_key(_), do: {:error, :bad_certificate}
end
