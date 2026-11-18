defmodule ColdForge.Markets do
  @moduledoc """
  Campaigns, in the screens' sense: a project's pushes ("Michigan", "Grand
  Rapids"), each holding its searches and email sequences. See
  `ColdForge.Markets.Market` for why the code calls them markets.

  A campaign's people are worked out rather than stored: whoever its searches
  added, plus whoever its sequences enrolled. `within/3` narrows any query to
  them, so the calls, postcards, replies and activity screens can show one
  campaign without each growing its own campaign key.
  """
  import Ecto.Query

  alias ColdForge.Calling.Call
  alias ColdForge.Inbox.Reply
  alias ColdForge.Markets.Market
  alias ColdForge.Outreach.{Campaign, Enrollment, Message}
  alias ColdForge.Postcards.Postcard
  alias ColdForge.Repo
  alias ColdForge.Sourcing.{Org, Source}

  def list_markets(project_id) do
    Market
    |> where([m], m.project_id == ^project_id)
    |> order_by([m], asc: m.name)
    |> Repo.all()
  end

  def get_market!(id), do: Repo.get!(Market, id)

  def create_market(attrs), do: %Market{} |> Market.changeset(attrs) |> Repo.insert()

  def update_market(%Market{} = market, attrs),
    do: market |> Market.changeset(attrs) |> Repo.update()

  @doc """
  Deletes the campaign only. Its searches and sequences stay in the project,
  outside any campaign, and keep running — the database nils their key.
  """
  def delete_market(%Market{} = market), do: Repo.delete(market)

  def change_market(%Market{} = market, attrs \\ %{}), do: Market.changeset(market, attrs)

  @doc "`{name, id}` pairs for a select, by name."
  def options(project_id), do: project_id |> list_markets() |> Enum.map(&{&1.name, &1.id})

  @doc """
  The ids of a campaign's people, as a query to use in a subquery: everyone its
  searches added, and everyone its sequences enrolled.
  """
  def prospect_ids(market_id) do
    found =
      from o in Org,
        join: s in Source,
        on: s.id == o.source_id,
        where: s.market_id == ^market_id and not is_nil(o.prospect_id),
        select: o.prospect_id

    enrolled =
      from e in Enrollment,
        join: c in Campaign,
        on: c.id == e.campaign_id,
        where: c.market_id == ^market_id,
        select: e.prospect_id

    union(found, ^enrolled)
  end

  @doc """
  Narrows a query to one campaign's people, by the prospect id in `field` of
  its first binding (`:id` on a prospect query, `:prospect_id` on anything
  that points at one). A `nil` campaign leaves the query alone, so a screen
  can pass whatever it has.
  """
  def within(query, market_id, field \\ :id)
  def within(query, nil, _field), do: query

  def within(query, market_id, field) do
    ids = prospect_ids(market_id)
    where(query, [x], field(x, ^field) in subquery(ids))
  end

  @doc """
  Searches and sequences that aren't in any campaign yet, so the project page
  can offer to move them into one.
  """
  def unassigned(project_id) do
    %{
      sources:
        Repo.all(
          from s in Source,
            where: s.project_id == ^project_id and is_nil(s.market_id),
            order_by: s.name
        ),
      campaigns:
        Repo.all(
          from c in Campaign,
            where: c.project_id == ^project_id and is_nil(c.market_id),
            order_by: c.name
        )
    }
  end

  @doc "Puts a search or a sequence in a campaign, or (with `nil`) in none."
  def assign(%Source{} = source, market_id),
    do: source |> Ecto.Changeset.change(market_id: blank_to_nil(market_id)) |> Repo.update()

  def assign(%Campaign{} = campaign, market_id),
    do: campaign |> Ecto.Changeset.change(market_id: blank_to_nil(market_id)) |> Repo.update()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(id), do: id

  @doc """
  The headline numbers for one campaign: what it holds, what's gone out, and
  what's come back.
  """
  def summary(%Market{id: id}) do
    sent_q =
      from m in Message,
        join: e in Enrollment,
        on: e.id == m.enrollment_id,
        join: c in Campaign,
        on: c.id == e.campaign_id,
        where: c.market_id == ^id and m.status == "sent"

    %{
      people: Repo.one(from(x in subquery(prospect_ids(id)), select: count())),
      searches: Repo.aggregate(from(s in Source, where: s.market_id == ^id), :count),
      sequences: Repo.aggregate(from(c in Campaign, where: c.market_id == ^id), :count),
      active_sequences:
        Repo.aggregate(
          from(c in Campaign, where: c.market_id == ^id and c.status == "active"),
          :count
        ),
      sent: Repo.aggregate(sent_q, :count),
      opened: Repo.aggregate(from([m] in sent_q, where: not is_nil(m.first_opened_at)), :count),
      replied:
        Repo.one(
          from(r in Reply,
            where: not r.automated,
            select: count(r.prospect_id, :distinct)
          )
          |> within(id, :prospect_id)
        ),
      calls: Repo.aggregate(within(Call, id, :prospect_id), :count),
      postcards: Repo.aggregate(within(Postcard, id, :prospect_id), :count)
    }
  end
end
