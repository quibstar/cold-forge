defmodule ColdForge.Inbox do
  @moduledoc """
  Replies coming back in.

  Matching runs strongest-first:

    1. `In-Reply-To` / `References` against the Message-ID we set on the send.
       Exact — it names one email to one person.
    2. The From address against a prospect. Weaker: it says who wrote, not what
       they were answering, and the same person may be in several campaigns.

  A matched reply stops that person's campaigns, for the same reason answering
  a survey does — following up on somebody who already wrote back is the
  fastest way to look like a machine.

  The exception is automated mail. An out-of-office is not a reply, and
  treating it as one would silently drop people out of campaigns while they are
  on holiday.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Message, Prospect}
  alias ColdForge.Inbox.Reply
  alias ColdForge.Repo

  @doc """
  Records an inbound email.

  Takes what every inbound provider gives you, however it spells it:

      %{
        from: "sam@riveraroofing.com",
        subject: "Re: Quick question",
        body: "...",
        in_reply_to: "<token@cold.example>",
        references: ["<token@cold.example>"],
        received_at: ~U[...],
        external_id: "provider-id"
      }

  Returns `{:ok, reply}`, `{:ok, :duplicate}` when the provider redelivers, or
  `{:error, :no_match}` when the sender is nobody we've written to — which is
  most of what arrives at a public address, and is not a failure.
  """
  def receive_email(params) do
    from = normalize(params[:from])
    received_at = params[:received_at] || DateTime.utc_now()

    case match(from, params) do
      nil ->
        {:error, :no_match}

      {prospect, message, matched_by} ->
        attrs = %{
          prospect_id: prospect.id,
          message_id: message && message.id,
          from_email: from,
          subject: params[:subject],
          body: params[:body],
          matched_by: matched_by,
          automated: automated?(params),
          received_at: DateTime.truncate(received_at, :second),
          external_id: params[:external_id]
        }

        if already_recorded?(params[:external_id]) do
          {:ok, :duplicate}
        else
          insert_and_apply(attrs, prospect)
        end
    end
  end

  # Providers retry. Asked before opening the transaction rather than caught as
  # a constraint violation inside one: a violation aborts the surrounding
  # transaction, so there is no way to return "that's fine" from within it.
  defp already_recorded?(nil), do: false
  defp already_recorded?(""), do: false

  defp already_recorded?(external_id),
    do: Repo.exists?(from r in Reply, where: r.external_id == ^external_id)

  defp insert_and_apply(attrs, prospect) do
    Repo.transaction(fn ->
      # `mode: :savepoint` so a violation from a redelivery that slipped past the
      # check above rolls back only this insert, leaving the transaction usable.
      case %Reply{} |> Reply.changeset(attrs) |> Repo.insert(mode: :savepoint) do
        {:ok, reply} ->
          # An out-of-office says the person is away, not that they answered.
          unless reply.automated, do: Outreach.mark_replied(prospect)
          reply

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :external_id),
            do: :duplicate,
            else: Repo.rollback(changeset)
      end
    end)
  end

  # A From header may be `Sam Rivera <sam@example.com>` or a bare address.
  defp normalize(nil), do: nil

  defp normalize(from) when is_binary(from) do
    case Regex.run(~r/<([^>]+)>/, from, capture: :all_but_first) do
      [address] -> clean(address)
      _ -> clean(from)
    end
  end

  defp clean(address), do: address |> String.trim() |> String.downcase()

  ## Matching

  defp match(nil, _params), do: nil

  defp match(from, params) do
    case match_by_message_id(params) do
      {prospect, message} ->
        {prospect, message, "exact"}

      nil ->
        case match_by_address(from) do
          nil -> nil
          prospect -> {prospect, nil, "address"}
        end
    end
  end

  # `References` carries the whole thread, so a reply to a reply still names our
  # original. `In-Reply-To` is checked first because it names the direct parent.
  defp match_by_message_id(params) do
    ids =
      [params[:in_reply_to] | List.wrap(params[:references])]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&extract_ids/1)
      |> Enum.uniq()

    case ids do
      [] ->
        nil

      ids ->
        Message
        |> where([m], m.rfc_message_id in ^ids)
        |> order_by([m], desc: m.sent_at)
        |> limit(1)
        |> preload(:prospect)
        |> Repo.one()
        |> case do
          nil -> nil
          message -> {message.prospect, message}
        end
    end
  end

  # Headers arrive as "<a@b> <c@d>" or already split; either way we want the
  # angle-bracketed ids.
  defp extract_ids(value) when is_binary(value) do
    case Regex.scan(~r/<([^>]+)>/, value, capture: :all_but_first) do
      [] -> [String.trim(value)]
      matches -> Enum.map(matches, fn [id] -> id end)
    end
  end

  defp extract_ids(_), do: []

  # Deliberately not scoped to a project: the same person may be a prospect for
  # two ideas, and a reply to either is still a reply from them. The most
  # recently mailed one wins.
  defp match_by_address(from) do
    from_prospect =
      Prospect
      |> where([p], p.email == ^from)
      |> Repo.all()

    case from_prospect do
      [] -> nil
      [only] -> only
      many -> most_recently_mailed(many)
    end
  end

  defp most_recently_mailed(prospects) do
    ids = Enum.map(prospects, & &1.id)

    latest =
      Message
      |> where([m], m.prospect_id in ^ids and not is_nil(m.sent_at))
      |> order_by([m], desc: m.sent_at)
      |> limit(1)
      |> Repo.one()

    case latest do
      nil -> List.first(prospects)
      message -> Enum.find(prospects, &(&1.id == message.prospect_id))
    end
  end

  ## Automated mail

  # Header-based first, because RFC 3834's `Auto-Submitted` and the de-facto
  # `X-Autoreply` are what well-behaved autoresponders set. The subject match is
  # a fallback for the ones that don't.
  @auto_subject ~r/\b(out of (the )?office|automatic reply|auto[- ]?reply|on (annual )?leave|vacation|undeliverable|delivery status notification|mail delivery failed)\b/i

  @doc """
  Whether an inbound message looks like a machine rather than a person.

  Erring toward *not* automated on purpose: mistaking a real reply for an
  auto-responder means chasing somebody who already answered, which is the
  worse failure.
  """
  def automated?(params) do
    headers = params[:headers] || %{}

    auto_submitted =
      headers
      |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
      |> then(fn h ->
        (h["auto-submitted"] || "") not in ["", "no"] or
          Map.has_key?(h, "x-autoreply") or
          Map.has_key?(h, "x-autorespond") or
          (h["precedence"] || "") in ["auto_reply", "bulk", "junk"]
      end)

    auto_submitted or Regex.match?(@auto_subject, params[:subject] || "")
  end

  ## Reading them

  def list_replies(project_id, limit \\ 100) do
    from(r in Reply,
      join: p in assoc(r, :prospect),
      where: p.project_id == ^project_id,
      order_by: [desc: r.received_at],
      limit: ^limit,
      preload: [prospect: p, message: []]
    )
    |> Repo.all()
  end

  def list_replies_for_prospect(prospect_id) do
    Reply
    |> where([r], r.prospect_id == ^prospect_id)
    |> order_by([r], desc: r.received_at)
    |> Repo.all()
  end

  @doc "How many people have written back on this project."
  def replied_count(project_id) do
    from(r in Reply,
      join: p in assoc(r, :prospect),
      where: p.project_id == ^project_id and not r.automated,
      select: count(r.prospect_id, :distinct)
    )
    |> Repo.one()
  end
end
