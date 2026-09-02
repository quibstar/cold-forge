defmodule ColdForge.Feedback do
  @moduledoc """
  Bounces and complaints, which are the two ways a send tells you to stop.

  Not optional bookkeeping: SES suspends accounts that run above roughly 5%
  bounces or 0.1% complaints, and it measures those whether or not anyone is
  reading. Cold outreach to addresses collected by hand starts well above 5%,
  so a list that does not clean itself takes the sending account down with it.

  Two distinctions do the real work here.

  **Permanent versus transient.** A permanent bounce means the address does not
  exist — suppress it. A transient one means a full mailbox or a throttled
  server, and the address is fine; suppressing on those quietly discards good
  prospects for a problem that fixes itself.

  **Complaints versus `not-spam`.** Both arrive as feedback, and they mean
  opposite things: `not-spam` is a recipient pulling the message *out* of their
  spam folder. Treating it as a complaint would suppress the most engaged
  person on the list.

  Suppression happens whether or not a prospect matches. SNS can deliver the
  same notification more than once, so everything here is idempotent —
  `suppress/3` ignores conflicts, and re-marking a prospect writes what is
  already there.
  """

  require Logger

  alias ColdForge.Outreach

  @doc """
  Records one SES notification.

  Returns `{:ok, summary}` for anything understood, including the kinds that
  deliberately do nothing — a caller cannot distinguish "ignored on purpose"
  from "failed" if both are errors, and the provider should not retry either.
  """
  def record(payload) when is_map(payload) do
    case payload["notificationType"] || payload["eventType"] do
      "Bounce" -> bounce(payload["bounce"] || %{})
      "Complaint" -> complaint(payload["complaint"] || %{})
      other -> {:ok, %{action: :ignored, kind: other}}
    end
  end

  def record(_), do: {:ok, %{action: :ignored, kind: nil}}

  # A permanent bounce is the address telling you it does not exist. Anything
  # else is temporary, and the address stays on the list.
  defp bounce(%{"bounceType" => "Permanent"} = bounce) do
    bounce
    |> Map.get("bouncedRecipients", [])
    |> stop(&suppress_bounce/2, diagnostic(bounce))
    |> summarize(:suppressed, "bounced")
  end

  defp bounce(bounce) do
    Logger.info(
      "transient bounce (#{bounce["bounceType"]}/#{bounce["bounceSubType"]}) — not suppressing"
    )

    {:ok, %{action: :ignored, kind: "Bounce", reason: :transient}}
  end

  # The recipient rescued the message from their spam folder. The opposite of a
  # complaint, and suppressing on it would drop the most engaged reader you have.
  defp complaint(%{"complaintFeedbackType" => "not-spam"}) do
    {:ok, %{action: :ignored, kind: "Complaint", reason: :not_spam}}
  end

  defp complaint(complaint) do
    complaint
    |> Map.get("complainedRecipients", [])
    |> stop(&suppress_complaint/2, complaint["complaintFeedbackType"])
    |> summarize(:suppressed, "complained")
  end

  defp stop(recipients, suppressor, notes) do
    recipients
    |> Enum.map(&address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn email ->
      suppressor.(email, notes)
      email
    end)
  end

  # Suppress first and unconditionally. SES will report a bounce for an address
  # whose prospect has since been deleted, and that address must still never be
  # written to again.
  defp suppress_bounce(email, notes) do
    Outreach.suppress(email, "bounced", %{notes: notes})
    Enum.each(Outreach.prospects_by_email(email), &Outreach.mark_bounced(&1, notes))
  end

  defp suppress_complaint(email, notes) do
    Outreach.suppress(email, "complained", %{notes: notes})
    Enum.each(Outreach.prospects_by_email(email), &Outreach.mark_complained(&1, notes))
  end

  defp summarize([], _action, _reason), do: {:ok, %{action: :ignored, emails: []}}

  defp summarize(emails, action, reason),
    do: {:ok, %{action: action, reason: reason, emails: emails}}

  # The diagnostic code is the mail server's own explanation ("550 5.1.1 user
  # unknown"), which is the only thing that later says *why* an address was
  # dropped.
  defp diagnostic(%{"bouncedRecipients" => [%{"diagnosticCode" => code} | _]})
       when is_binary(code),
       do: code

  defp diagnostic(%{"bounceSubType" => subtype}), do: subtype
  defp diagnostic(_), do: nil

  defp address(%{"emailAddress" => email}) when is_binary(email), do: normalize(email)
  defp address(email) when is_binary(email), do: normalize(email)
  defp address(_), do: nil

  # SES usually sends a bare address, but the field is documented as an RFC 5322
  # address and may carry a display name.
  defp normalize(value) do
    case Regex.run(~r/<([^>]+)>/, value, capture: :all_but_first) do
      [address] -> clean(address)
      _ -> clean(value)
    end
  end

  defp clean(address) do
    case address |> String.trim() |> String.downcase() do
      "" -> nil
      address -> address
    end
  end
end
