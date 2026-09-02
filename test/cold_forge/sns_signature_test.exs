defmodule ColdForge.SNS.SignatureTest do
  @moduledoc """
  Signature verification is what makes it safe for the app to confirm its own
  subscriptions, so the cases that must *fail* matter more than the one that
  passes — a verifier that accepts everything is worse than none, because it
  looks like protection.
  """
  use ExUnit.Case, async: true

  alias ColdForge.SNS

  @cert_url "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem"

  setup do
    cert = File.read!("test/support/fixtures/sns/test_cert.pem")
    # openssl writes PKCS#8; pem_entry_decode unwraps it to the RSAPrivateKey
    # that :public_key.sign/3 expects.
    key =
      "test/support/fixtures/sns/test_key.pem"
      |> File.read!()
      |> :public_key.pem_decode()
      |> hd()
      |> :public_key.pem_entry_decode()

    Application.put_env(:cold_forge, :sns_cert_fetcher, fn _url -> {:ok, cert} end)
    on_exit(fn -> Application.delete_env(:cold_forge, :sns_cert_fetcher) end)

    %{key: key}
  end

  defp sign(params, key) do
    signature =
      params
      |> SNS.Signature.string_to_sign()
      |> :public_key.sign(:sha256, key)
      |> Base.encode64()

    Map.merge(params, %{
      "SignatureVersion" => "2",
      "Signature" => signature,
      "SigningCertURL" => @cert_url
    })
  end

  defp notification(overrides \\ %{}) do
    Map.merge(
      %{
        "Type" => "Notification",
        "MessageId" => "abc-123",
        "TopicArn" => "arn:aws:sns:us-east-1:1:cold-forge-feedback",
        "Message" => ~s({"notificationType":"Bounce"}),
        "Timestamp" => "2026-09-02T12:00:00.000Z"
      },
      overrides
    )
  end

  test "accepts a genuine signature", %{key: key} do
    assert :ok == notification() |> sign(key) |> SNS.Signature.verify()
  end

  test "rejects a tampered message", %{key: key} do
    signed = notification() |> sign(key)
    tampered = %{signed | "Message" => ~s({"notificationType":"Delivery"})}

    assert {:error, :bad_signature} = SNS.Signature.verify(tampered)
  end

  test "rejects a signature lifted from another message", %{key: key} do
    stolen = notification() |> sign(key) |> Map.get("Signature")
    other = notification(%{"MessageId" => "different"})

    assert {:error, :bad_signature} =
             SNS.Signature.verify(
               Map.merge(other, %{
                 "Signature" => stolen,
                 "SigningCertURL" => @cert_url,
                 "SignatureVersion" => "2"
               })
             )
  end

  test "refuses a certificate URL that is not Amazon's" do
    # Without this check, verification becomes a request-forgery gadget: the
    # caller names a host and the server fetches it.
    for url <- [
          "https://evil.example.com/cert.pem",
          "http://sns.us-east-1.amazonaws.com/cert.pem",
          "https://sns.us-east-1.amazonaws.com.evil.example.com/cert.pem"
        ] do
      params = notification(%{"Signature" => "AAAA", "SigningCertURL" => url})

      assert {:error, :bad_cert_url} = SNS.Signature.verify(params),
             "should have refused #{url}"
    end
  end

  test "an unsigned payload is reported as such, not as valid" do
    # Other providers POST unsigned; the URL secret guards those. What must
    # never happen is `:ok`, which would let anything through as verified.
    assert :not_signed == SNS.Signature.verify(%{"from" => "someone@example.com"})
  end

  test "a confirmation signs a different field set than a notification", %{key: key} do
    confirmation =
      %{
        "Type" => "SubscriptionConfirmation",
        "MessageId" => "conf-1",
        "TopicArn" => "arn:aws:sns:us-east-1:1:cold-forge-feedback",
        "Message" => "You have chosen to subscribe",
        "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription",
        "Token" => "tok",
        "Timestamp" => "2026-09-02T12:00:00.000Z"
      }
      |> sign(key)

    assert :ok == SNS.Signature.verify(confirmation)

    # SubscribeURL is inside the signed set, which is what makes following it safe.
    tampered = %{confirmation | "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?evil"}
    assert {:error, :bad_signature} = SNS.Signature.verify(tampered)
  end

  describe "confirm/2" do
    test "refuses a subscribe URL that is not Amazon's" do
      assert {:error, :bad_subscribe_url} = SNS.confirm("https://evil.example.com/x", "arn:x")

      assert {:error, :bad_subscribe_url} =
               SNS.confirm("http://sns.us-east-1.amazonaws.com/x", "arn:x")
    end

    test "honours a topic allowlist when one is configured" do
      Application.put_env(:cold_forge, :sns_topic_arns, ["arn:aws:sns:us-east-1:1:mine"])
      on_exit(fn -> Application.delete_env(:cold_forge, :sns_topic_arns) end)

      assert {:error, :topic_not_allowed} =
               SNS.confirm(
                 "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription",
                 "arn:aws:sns:us-east-1:1:someone-elses"
               )
    end
  end
end
