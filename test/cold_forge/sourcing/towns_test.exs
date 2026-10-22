defmodule ColdForge.Sourcing.TownsTest do
  @moduledoc """
  A state in a search's "Where" becomes its towns, because Google Places caps
  a text search at 60 results — "roofing contractor in Michigan" would return
  60 roofers for the whole state.
  """
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Towns

  test "recognises a state by name or code, in any case" do
    assert Towns.state_code("Michigan") == "MI"
    assert Towns.state_code("michigan") == "MI"
    assert Towns.state_code("MI") == "MI"
    assert Towns.state_code("mi") == "MI"
    assert Towns.state_code(" New York ") == "NY"
  end

  test "a town is not a state, and neither is a code that isn't one" do
    refute Towns.state_code("Grand Rapids, MI")
    refute Towns.state_code("MX")
    refute Towns.state_code("")
  end

  test "a state becomes its towns of 5,000+, largest first" do
    towns = Towns.towns("MI")

    assert hd(towns) == "Detroit, MI"
    assert "Grand Rapids, MI" in towns
    assert Enum.all?(towns, &String.ends_with?(&1, ", MI"))
    assert length(towns) > 100
  end

  test "a bare state stays at 5,000+, so it can't quietly cost more" do
    assert Enum.all?(Towns.in_state("MI", 5_000), &(&1.population >= 5_000))
    assert length(Towns.towns("MI")) == length(Towns.in_state("MI", 5_000))
  end

  test "the picker can go down to towns of 1,000, for rural businesses" do
    small = Towns.in_state("MI", 1_000)

    assert length(small) > length(Towns.towns("MI"))
    assert Enum.all?(small, &(&1.population >= 1_000))
    assert Enum.any?(small, &(&1.population < 5_000))
  end

  describe "near/3" do
    test "finds towns within a distance, nearest first, centre included" do
      towns = Towns.near("Grand Rapids, MI", 10, 1_000)
      labels = Enum.map(towns, & &1.label)

      assert hd(labels) == "Grand Rapids, MI"
      assert "Grandville, MI" in labels
      refute "Detroit, MI" in labels
      assert Enum.all?(towns, &(&1.miles <= 10))
      assert towns == Enum.sort_by(towns, & &1.miles)
    end

    test "crosses state lines, because the work does" do
      states = "Monroe, MI" |> Towns.near(25, 5_000) |> Enum.map(& &1.state) |> Enum.uniq()
      assert "OH" in states
    end

    test "an unknown centre is nil rather than everywhere" do
      assert Towns.near("Nowhere, MI", 50, 1_000) == nil
      assert Towns.near("Grand Rapids", 50, 1_000) == nil
    end

    test "finds the centre whatever the case" do
      assert Towns.find("grand rapids, mi").label == "Grand Rapids, MI"
    end
  end

  test "anything that isn't a state is searched as written" do
    assert Towns.expand("Holland, MI") == ["Holland, MI"]
    assert Towns.expand("Michigan") == Towns.towns("MI")
  end
end
