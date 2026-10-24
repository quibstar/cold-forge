defmodule ColdForgeWeb.PaginationTest do
  @moduledoc """
  Which page numbers the control offers.

  The interesting part is what it leaves out. A list can run to hundreds of
  pages and the control has to stay one line, so most of them collapse — but
  collapsing the wrong ones makes it useless to navigate with.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp render(page, pages) do
    render_component(&ColdForgeWeb.CoreComponents.pagination/1,
      page: page,
      pages: pages,
      total: pages * 50,
      per_page: 50
    )
  end

  # The numbers on the buttons, in order, with the ellipsis as "…".
  defp labels(html) do
    ~r/aria-label="Page (\d+)"|(…)/
    |> Regex.scan(html)
    |> Enum.map(fn
      [_, n, _] when n != "" -> n
      [_, _, gap] -> gap
      [_, n] -> n
    end)
  end

  test "a short list offers every page" do
    assert labels(render(1, 3)) == ["1", "2", "3"]
  end

  test "a long list keeps the ends and the neighbourhood" do
    assert labels(render(10, 20)) == ["1", "…", "9", "10", "11", "…", "20"]
  end

  test "near the start there is nothing to collapse on the left" do
    assert labels(render(1, 20)) == ["1", "2", "…", "20"]
  end

  test "near the end there is nothing to collapse on the right" do
    assert labels(render(20, 20)) == ["1", "…", "19", "20"]
  end

  test "a gap is never one hidden page" do
    # Page 4 of 20 would skip only page 2. An ellipsis standing in for a single
    # number is wider than the number, so the number stays.
    assert labels(render(4, 20)) == ["1", "2", "3", "4", "5", "…", "20"]
  end

  test "the current page is marked for screen readers, not only in colour" do
    html = render(7, 20)

    assert html =~ ~s(aria-current="page" aria-label="Page 7")
    assert html =~ "btn-active"
  end

  test "the arrows disable at the ends rather than disappearing" do
    first = render(1, 5)
    last = render(5, 5)

    assert first =~
             ~r/aria-label="Previous page"[^>]*disabled|disabled[^>]*aria-label="Previous page"/

    refute first =~ ~r/aria-label="Next page"[^>]*disabled|disabled[^>]*aria-label="Next page"/

    assert last =~ ~r/aria-label="Next page"[^>]*disabled|disabled[^>]*aria-label="Next page"/

    refute last =~
             ~r/aria-label="Previous page"[^>]*disabled|disabled[^>]*aria-label="Previous page"/
  end
end
