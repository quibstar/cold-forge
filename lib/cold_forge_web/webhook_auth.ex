defmodule ColdForgeWeb.WebhookAuth do
  @moduledoc """
  The shared secret guarding the machine-to-machine endpoints.

  One secret covers both SNS subscriptions — replies and feedback — because
  they come from the same account over the same channel, and a second secret
  would be one more thing to rotate for no additional isolation.
  """

  @doc """
  Compares a token from the URL against the configured secret.

  Constant-time: a secret checked with `==` leaks its length and prefix to
  anyone willing to time the responses. Unconfigured means unauthorized, so a
  deploy that forgets to set one fails closed.
  """
  def authorized?(token) when is_binary(token) do
    case Application.get_env(:cold_forge, :inbound_token) do
      secret when is_binary(secret) and secret != "" ->
        Plug.Crypto.secure_compare(token, secret)

      _ ->
        false
    end
  end

  def authorized?(_), do: false
end
