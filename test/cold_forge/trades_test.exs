defmodule ColdForge.TradesTest do
  @moduledoc """
  Filtering prospects and the call queue by trade, where a trade is the
  prospect's `industry` however the list that carried it spelled it.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Calling, Outreach}

  setup do
    project = project_fixture()

    roofer = prospect_fixture(project, industry: "roofers", phone: "6165550101")
    roofing = prospect_fixture(project, industry: "roofing", phone: "6165550102")

    siding =
      prospect_fixture(project, industry: "siding and gutter contractors", phone: "6165550103")

    blank = prospect_fixture(project, industry: nil, phone: "6165550104")

    %{project: project, roofer: roofer, roofing: roofing, siding: siding, blank: blank}
  end

  test "roofers and roofing are one trade, biggest first", %{project: project} do
    assert [
             %{key: "roofing", label: "Roofing", count: 2},
             %{key: "siding and gutter contractors", count: 1}
           ] = Outreach.list_trades(project.id)
  end

  test "the prospect list narrows to a trade", %{project: project} = ctx do
    ids = project.id |> Outreach.list_prospects(trade: "roofing") |> Enum.map(& &1.id)
    assert Enum.sort(ids) == Enum.sort([ctx.roofer.id, ctx.roofing.id])

    assert length(Outreach.list_prospects(project.id, trade: "")) == 4
  end

  test "the call queue narrows to a trade", %{project: project} = ctx do
    assert [%{id: id}] = Calling.queue(project.id, trade: "siding and gutter contractors")
    assert id == ctx.siding.id

    assert length(Calling.queue(project.id)) == 4
  end

  test "filtering leaves the stored industry alone", %{project: project} = ctx do
    Outreach.list_prospects(project.id, trade: "roofing")
    assert Outreach.get_prospect!(ctx.roofer.id).industry == "roofers"
  end
end
