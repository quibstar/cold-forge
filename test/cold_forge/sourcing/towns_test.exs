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

  test "anything that isn't a state is searched as written" do
    assert Towns.expand("Holland, MI") == ["Holland, MI"]
    assert Towns.expand("Michigan") == Towns.towns("MI")
  end
end
