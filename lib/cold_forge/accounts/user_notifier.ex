defmodule ColdForge.Accounts.UserNotifier do
  import Swoosh.Email

  alias ColdForge.Mailer
  alias ColdForge.Accounts.User

  # Delivers the email using the application mailer.
  # Operator mail — magic links and confirmations — is the one kind this app
  # sends to itself rather than to a prospect, so it has no project to take a
  # from-address from.
  #
  # It must still be an address SES will accept. The generator's default,
  # contact@example.com, is not a verified identity, so every login email was
  # rejected by SES and the magic link simply never arrived: no bounce to see,
  # and a log-in page that looks like it worked.
  defp from_address do
    Application.get_env(:cold_forge, :operator_from_email) || "contact@example.com"
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Cold Forge", from_address()})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
