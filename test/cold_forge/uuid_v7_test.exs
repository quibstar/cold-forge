defmodule ColdForge.UUIDv7Test do
  @moduledoc """
  The properties the rest of the schema depends on: version 7 layout, and
  time-ordering — which is the entire reason for choosing v7 over the v4 Ecto
  would generate on its own.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.UUIDv7

  test "generates a well-formed version 7 UUID" do
    {:ok, raw} = Ecto.UUID.dump(UUIDv7.generate())
    <<_ts::48, version::4, _rand_a::12, variant::2, _rand_b::62>> = raw

    assert version == 7
    # RFC 9562 variant bits are 0b10.
    assert variant == 2
  end

  test "encodes the current time in the first 48 bits" do
    before = DateTime.utc_now()
    {:ok, stamped} = UUIDv7.timestamp(UUIDv7.generate())

    assert DateTime.diff(stamped, before, :second) |> abs() <= 2
  end

  test "ids minted in different milliseconds sort chronologically" do
    first = UUIDv7.generate()
    Process.sleep(2)
    second = UUIDv7.generate()

    assert first < second
  end

  test "does not collide" do
    ids = for _ <- 1..10_000, do: UUIDv7.generate()
    assert length(Enum.uniq(ids)) == 10_000
  end

  describe "as a primary key" do
    test "rows come back in insertion order when sorted by id", %{} do
      project = project_fixture()

      prospects =
        for _ <- 1..5 do
          Process.sleep(2)
          prospect_fixture(project)
        end

      by_id =
        ColdForge.Outreach.Prospect
        |> Ecto.Query.where([p], p.project_id == ^project.id)
        |> Ecto.Query.order_by([p], asc: p.id)
        |> Repo.all()

      # This is what a v7 buys over a v4: the primary key index is also a
      # chronological index, so inserts append rather than scatter.
      assert Enum.map(by_id, & &1.id) == Enum.map(prospects, & &1.id)
    end

    test "associations resolve across UUID foreign keys" do
      project = project_fixture()
      prospect = prospect_fixture(project)

      loaded = Repo.preload(prospect, :project)
      assert loaded.project.id == project.id
    end
  end
end
