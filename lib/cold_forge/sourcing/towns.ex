defmodule ColdForge.Sourcing.Towns do
  @moduledoc """
  Turns a state into the towns to search in it.

  Google Places caps a text search at 60 results, so "roofing contractor in
  Michigan" would return 60 roofers for the whole state. Coverage comes from
  many narrow searches instead: one per town. When somebody types "Michigan"
  into a search's "Where", it becomes every Michigan town of 5,000 people or
  more, largest first.

  The list is `priv/data/us_towns.csv`: incorporated places of 5,000+ from the
  Census Bureau's 2024 population estimates (`sub-est2024.csv`, public domain),
  trimmed to state, town and population. Smaller places are left out on
  purpose — Google's results for a town already reach into the townships and
  villages around it, and every extra town is another billed search per trade.

  Loaded once, on first use, and kept in `:persistent_term`.
  """

  @states %{
    "AL" => "Alabama",
    "AK" => "Alaska",
    "AZ" => "Arizona",
    "AR" => "Arkansas",
    "CA" => "California",
    "CO" => "Colorado",
    "CT" => "Connecticut",
    "DE" => "Delaware",
    "DC" => "District of Columbia",
    "FL" => "Florida",
    "GA" => "Georgia",
    "HI" => "Hawaii",
    "ID" => "Idaho",
    "IL" => "Illinois",
    "IN" => "Indiana",
    "IA" => "Iowa",
    "KS" => "Kansas",
    "KY" => "Kentucky",
    "LA" => "Louisiana",
    "ME" => "Maine",
    "MD" => "Maryland",
    "MA" => "Massachusetts",
    "MI" => "Michigan",
    "MN" => "Minnesota",
    "MS" => "Mississippi",
    "MO" => "Missouri",
    "MT" => "Montana",
    "NE" => "Nebraska",
    "NV" => "Nevada",
    "NH" => "New Hampshire",
    "NJ" => "New Jersey",
    "NM" => "New Mexico",
    "NY" => "New York",
    "NC" => "North Carolina",
    "ND" => "North Dakota",
    "OH" => "Ohio",
    "OK" => "Oklahoma",
    "OR" => "Oregon",
    "PA" => "Pennsylvania",
    "RI" => "Rhode Island",
    "SC" => "South Carolina",
    "SD" => "South Dakota",
    "TN" => "Tennessee",
    "TX" => "Texas",
    "UT" => "Utah",
    "VT" => "Vermont",
    "VA" => "Virginia",
    "WA" => "Washington",
    "WV" => "West Virginia",
    "WI" => "Wisconsin",
    "WY" => "Wyoming"
  }

  @by_name Map.new(@states, fn {code, name} -> {String.downcase(name), code} end)

  @doc """
  The two-letter code when `text` is a whole state, `nil` otherwise.

  Accepts the name or the code in any case: "Michigan", "michigan", "MI".
  Anything with a town in it — "Grand Rapids, MI" — is not a state.
  """
  def state_code(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      Map.has_key?(@states, String.upcase(trimmed)) and String.length(trimmed) == 2 ->
        String.upcase(trimmed)

      true ->
        Map.get(@by_name, String.downcase(trimmed))
    end
  end

  def state_code(_text), do: nil

  @doc "The state's full name, for display."
  def state_name(code), do: Map.get(@states, code)

  @doc ~s(Every town of 5,000+ in a state, largest first, as "Town, ST".)
  def towns(code) do
    all() |> Map.get(code, []) |> Enum.map(fn town -> "#{town}, #{code}" end)
  end

  @doc """
  What a "Where" line searches: a state becomes its towns, anything else is
  searched as written.
  """
  def expand(locality) do
    case state_code(locality) do
      nil -> [locality]
      code -> towns(code)
    end
  end

  defp all do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        towns = load()
        :persistent_term.put(__MODULE__, towns)
        towns

      towns ->
        towns
    end
  end

  # Rows arrive sorted by state, then population descending, so each state's
  # list keeps that order.
  defp load do
    :cold_forge
    |> Application.app_dir("priv/data/us_towns.csv")
    |> File.read!()
    |> ColdForge.Outreach.Importer.Parser.parse_string(skip_headers: true)
    |> Enum.reduce(%{}, fn [state, town, _population], acc ->
      Map.update(acc, state, [town], &[town | &1])
    end)
    |> Map.new(fn {state, towns} -> {state, Enum.reverse(towns)} end)
  end
end
