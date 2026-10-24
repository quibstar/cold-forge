defmodule ColdForge.ProspectPagingTest do
  @moduledoc """
  The prospect list is paged because sourcing fills it. A crawl of two trades
  across two towns added 55 organisations in minutes; rendering every row stops
  being usable long before it stops working.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup do
    project = project_fixture(name: "Paging")
    per = Outreach.per_page()

    for i <- 1..(per + 10) do
      prospect_fixture(project, company: "Company #{String.pad_leading("#{i}", 3, "0")}")
    end

    %{project: project, per: per}
  end

  test "a page holds at most per_page", %{project: project, per: per} do
    assert length(Outreach.list_prospects(project.id)) == per
  end

  test "the next page is the rest, and nothing repeats", %{project: project, per: per} do
    one = Outreach.list_prospects(project.id, page: 1)
    two = Outreach.list_prospects(project.id, page: 2)

    assert length(two) == 10
    assert MapSet.disjoint?(MapSet.new(one, & &1.id), MapSet.new(two, & &1.id))
    assert Outreach.page_count(project.id) == 2
    assert Outreach.count_prospects(project.id) == per + 10
  end

  test "paging is stable when rows share a timestamp", %{project: project, per: per} do
    # An import writes a hundred rows in the same second. Ordering on
    # inserted_at alone leaves their order undefined, so a row could land on
    # two pages or on neither. Every row must appear exactly once.
    one = Outreach.list_prospects(project.id, page: 1)
    two = Outreach.list_prospects(project.id, page: 2)
    seen = Enum.map(one ++ two, & &1.id)

    assert length(seen) == per + 10
    assert length(Enum.uniq(seen)) == per + 10
    assert MapSet.new(seen) == project.id |> all_prospect_ids() |> MapSet.new()
  end

  defp all_prospect_ids(project_id) do
    import Ecto.Query

    ColdForge.Repo.all(
      from p in ColdForge.Outreach.Prospect, where: p.project_id == ^project_id, select: p.id
    )
  end

  test "a page past the end is empty rather than an error", %{project: project} do
    assert Outreach.list_prospects(project.id, page: 99) == []
  end

  test "page 0 or a negative page is treated as the first", %{project: project, per: per} do
    assert length(Outreach.list_prospects(project.id, page: 0)) == per
    assert length(Outreach.list_prospects(project.id, page: -3)) == per
  end

  test "the count ignores paging but respects filters", %{project: project, per: per} do
    assert Outreach.count_prospects(project.id, page: 2) == per + 10
    assert Outreach.count_prospects(project.id, search: "Company 001") == 1
    assert Outreach.page_count(project.id, search: "Company 001") == 1
  end

  test "an empty result still reports one page, not zero", %{project: project} do
    assert Outreach.count_prospects(project.id, search: "nothing matches this") == 0
    # Zero pages would make "Page 1 of 0" and a clamp to 0.
    assert Outreach.page_count(project.id, search: "nothing matches this") == 1
  end
end
