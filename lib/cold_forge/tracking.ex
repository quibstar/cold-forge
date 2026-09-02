defmodule ColdForge.Tracking do
  @moduledoc """
  Records what recipients did: clicked a link, opened a message, unsubscribed.

  Every function here runs on a request from the open internet, triggered by a
  token in an email. They must never raise on an unknown token — a bot hitting
  `/c/garbage` is routine, not an error.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Outreach.Message
  alias ColdForge.Repo
  alias ColdForge.Tracking.{LinkClick, TrackedLink}

  @doc "Looks up a tracked link by the token in a `/c/:token` URL."
  def get_tracked_link(token) when is_binary(token) do
    TrackedLink
    |> Repo.get_by(token: token)
    |> Repo.preload(message: [:prospect, :project])
  end

  def get_tracked_link(_), do: nil

  @doc """
  Records a click and returns the destination to redirect to, with a `cf`
  attribution parameter appended so the receiving site can tie the visit back
  to the send.
  """
  def record_click(%TrackedLink{} = link, meta \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Repo.insert!(
        LinkClick.changeset(%LinkClick{}, %{
          tracked_link_id: link.id,
          ip: meta[:ip],
          user_agent: meta[:user_agent],
          clicked_at: now
        })
      )

      # Increment in SQL rather than read-modify-write: two clicks landing at
      # once would otherwise both write the same count.
      TrackedLink
      |> where([l], l.id == ^link.id)
      |> Repo.update_all(inc: [click_count: 1])

      # Separate statement, guarded on NULL, so a second click can't overwrite
      # the timestamp of the first one.
      TrackedLink
      |> where([l], l.id == ^link.id and is_nil(l.first_clicked_at))
      |> Repo.update_all(set: [first_clicked_at: now])

      :ok
    end)

    destination_with_attribution(link)
  end

  # The `cf` param is what lets ExteriorPro's demo form know which cold email
  # produced the lead. It's the link token, not the prospect id — nothing about
  # the recipient is exposed in a URL they could share.
  defp destination_with_attribution(%TrackedLink{} = link) do
    uri = URI.parse(link.destination_url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("cf", link.token)
      |> URI.encode_query()

    uri |> Map.put(:query, query) |> URI.to_string()
  end

  @doc """
  Records an open against the `/o/:token.png` pixel.

  Opens are the least trustworthy signal here — image proxies at Gmail and
  Outlook fetch the pixel before a human sees anything — so the count is kept
  but never used to stop or branch a campaign.
  """
  def record_open(token) when is_binary(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Message
      |> where([m], m.open_token == ^token)
      |> Repo.update_all(inc: [open_count: 1])

    # Guarded on NULL so repeat opens keep the timestamp of the first one.
    Message
    |> where([m], m.open_token == ^token and is_nil(m.first_opened_at))
    |> Repo.update_all(set: [first_opened_at: now])

    if count == 0, do: :not_found, else: :ok
  end

  def record_open(_), do: :not_found

  @doc "Clicks for a message, newest first — the activity view for one send."
  def list_clicks(message_id) do
    from(c in LinkClick,
      join: l in assoc(c, :tracked_link),
      where: l.message_id == ^message_id,
      order_by: [desc: c.clicked_at],
      preload: [tracked_link: l]
    )
    |> Repo.all()
  end
end
