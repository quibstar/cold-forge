defmodule ColdForge.MarketsTest do
  @moduledoc """
  Campaigns (markets in code): who is in one, and that every screen's list can
  be narrowed to them. The rule that matters is that a campaign's people are
  exactly whoever its searches added or its sequences enrolled — nobody from
  the campaign next door.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Calling, Inbox, Markets, Outreach, Repo}
  alias ColdForge.Inbox.Reply
  alias ColdForge.Sourcing.{Org, Source}

  setup do
    project = project_fixture(name: "ExteriorPro")
    {:ok, michigan} = Markets.create_market(%{project_id: project.id, name: "Michigan"})
    {:ok, texas} = Markets.create_market(%{project_id: project.id, name: "Texas"})
    %{project: project, michigan: michigan, texas: texas}
  end

  defp search(ctx, market, name) do
    Repo.insert!(%Source{
      name: name,
      project_id: ctx.project.id,
      market_id: market && market.id,
      provider: "places",
      segments: ["roofing"],
      localities: [name]
    })
  end

  # A prospect added from a search result.
  defp found(ctx, source, attrs \\ %{}) do
    prospect = prospect_fixture(ctx.project, attrs)

    Repo.insert!(%Org{
      source_id: source.id,
      provider: "places",
      source_ref: "ref-#{System.unique_integer([:positive])}",
      segment: "roofing",
      name: prospect.company,
      prospect_id: prospect.id
    })

    prospect
  end

  test "a campaign's people are who its searches added and its sequences enrolled", ctx do
    mi_search = search(ctx, ctx.michigan, "Michigan")
    tx_search = search(ctx, ctx.texas, "Texas")

    from_search = found(ctx, mi_search)
    _texan = found(ctx, tx_search)
    _imported = prospect_fixture(ctx.project)

    enrolled = prospect_fixture(ctx.project)
    sequence = campaign_fixture(ctx.project, %{market_id: ctx.michigan.id})
    step_fixture(sequence)
    {:ok, _} = Outreach.enroll_prospect(sequence, enrolled)

    ids = ctx.project.id |> Outreach.list_prospects(market_id: ctx.michigan.id) |> ids()
    assert ids == Enum.sort([from_search.id, enrolled.id])

    assert Outreach.count_prospects(ctx.project.id, market_id: ctx.michigan.id) == 2
    assert Outreach.count_prospects(ctx.project.id) == 4
    assert Markets.summary(ctx.michigan).people == 2
  end

  test "someone both found and enrolled counts once", ctx do
    source = search(ctx, ctx.michigan, "Michigan")
    prospect = found(ctx, source)
    sequence = campaign_fixture(ctx.project, %{market_id: ctx.michigan.id})
    step_fixture(sequence)
    {:ok, _} = Outreach.enroll_prospect(sequence, prospect)

    assert Markets.summary(ctx.michigan).people == 1
    assert [_] = Outreach.list_prospects(ctx.project.id, market_id: ctx.michigan.id)
  end

  test "calls and replies narrow to the campaign", ctx do
    mi = found(ctx, search(ctx, ctx.michigan, "Michigan"), %{phone: "616-555-0100"})
    tx = found(ctx, search(ctx, ctx.texas, "Texas"), %{phone: "214-555-0100"})

    assert [%{id: id}] = Calling.queue(ctx.project.id, market_id: ctx.michigan.id)
    assert id == mi.id
    assert length(Calling.queue(ctx.project.id)) == 2

    for p <- [mi, tx] do
      Repo.insert!(%Reply{
        prospect_id: p.id,
        from_email: p.email,
        matched_by: "exact",
        subject: "Re: hi",
        body: "Tell me more",
        received_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    assert [reply] = Inbox.list_replies(ctx.project.id, 100, market_id: ctx.texas.id)
    assert reply.prospect_id == tx.id
    assert Inbox.replied_count(ctx.project.id, market_id: ctx.texas.id) == 1
    assert Inbox.replied_count(ctx.project.id) == 2
    assert Markets.summary(ctx.texas).replied == 1
  end

  test "searches and sequences outside every campaign are listed until moved", ctx do
    loose_search = search(ctx, nil, "Ohio")
    loose_sequence = campaign_fixture(ctx.project)
    _placed = campaign_fixture(ctx.project, %{market_id: ctx.texas.id})

    assert %{sources: [s], campaigns: [c]} = Markets.unassigned(ctx.project.id)
    assert {s.id, c.id} == {loose_search.id, loose_sequence.id}

    {:ok, _} = Markets.assign(loose_search, ctx.michigan.id)
    {:ok, _} = Markets.assign(loose_sequence, ctx.michigan.id)

    assert %{sources: [], campaigns: []} = Markets.unassigned(ctx.project.id)

    assert Markets.summary(ctx.michigan) |> Map.take([:searches, :sequences]) ==
             %{searches: 1, sequences: 1}
  end

  test "deleting a campaign keeps its searches and sequences, and they keep running", ctx do
    source = search(ctx, ctx.michigan, "Michigan")
    sequence = campaign_fixture(ctx.project, %{market_id: ctx.michigan.id, status: "active"})

    {:ok, _} = Markets.delete_market(ctx.michigan)

    assert Repo.reload(source).market_id == nil
    assert %{market_id: nil, status: "active"} = Repo.reload(sequence)
  end

  defp ids(prospects), do: prospects |> Enum.map(& &1.id) |> Enum.sort()
end
