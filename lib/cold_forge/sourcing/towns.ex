defmodule ColdForge.Sourcing.Towns do
  @moduledoc """
  Turns a state into the towns to search in it.

  Google Places caps a text search at 60 results, so "roofing contractor in
  Michigan" would return 60 roofers for the whole state. Coverage comes from
  many narrow searches instead: one per town. When somebody types "Michigan"
  into a search's "Where", it becomes every Michigan town of 5,000 people or
  more, largest first.

  The town picker goes further: a state at any population cutoff down to
  1,000, or every town within some distance of another. The small towns are
  there for rural businesses — breeders, farms — which a 5,000 cutoff misses
  entirely, since Google's results for a town reach into the countryside
  around it but not into the next county.

  The list is `priv/data/us_towns.csv`: incorporated places of 1,000+ from the
  Census Bureau's 2024 population estimates (`sub-est2024.csv`), joined to
  each place's coordinates from the 2024 Gazetteer
  (`2024_Gaz_place_national.txt`). Both are public domain.

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

  # What a bare state name expands to. Kept at 5,000 so typing "Michigan" can't
  # quietly turn into several hundred searches; the picker is where smaller
  # towns are chosen deliberately, with the cost on screen.
  @state_default_population 5_000

  @doc "Population cutoffs the picker offers. The data goes no lower than the first."
  def population_options, do: [1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]

  @doc "Distances, in miles, the picker offers."
  def mile_options, do: [10, 25, 50, 75, 100, 150]

  @doc "Every state, as `{name, code}`, sorted by name — for a select."
  def state_options do
    @states |> Enum.map(fn {code, name} -> {name, code} end) |> Enum.sort()
  end

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
    code |> in_state(@state_default_population) |> Enum.map(& &1.label)
  end

  @doc """
  A state's towns at or above `min_population`, largest first.

  Each is a map with `:label` ("Holland, MI"), `:name`, `:state`,
  `:population`, `:lat` and `:lon`.
  """
  def in_state(code, min_population) do
    all() |> Map.get(code, []) |> Enum.filter(&(&1.population >= min_population))
  end

  @doc """
  Every town within `miles` of `center` (a label like "Grand Rapids, MI"),
  nearest first, with its distance in `:miles`. Crosses state lines: a shop in
  Monroe, MI works Toledo too.

  `nil` when the centre isn't a town in the list.
  """
  def near(center, miles, min_population) do
    case find(center) do
      nil ->
        nil

      origin ->
        all()
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.population >= min_population))
        |> Enum.map(&Map.put(&1, :miles, distance(origin, &1)))
        |> Enum.filter(&(&1.miles <= miles))
        |> Enum.sort_by(& &1.miles)
    end
  end

  @doc ~s(The town with this label, e.g. "Grand Rapids, MI", or `nil`.)
  def find(label) when is_binary(label) do
    with [name, code] <- label |> String.split(",") |> Enum.map(&String.trim/1),
         code = String.upcase(code) do
      all()
      |> Map.get(code, [])
      |> Enum.find(&(String.downcase(&1.name) == String.downcase(name)))
    else
      _ -> nil
    end
  end

  def find(_label), do: nil

  # Great-circle distance in miles. Straight-line, not driving — close enough
  # to decide which towns a shop could plausibly work.
  defp distance(%{lat: lat1, lon: lon1}, %{lat: lat2, lon: lon2}) do
    rad = :math.pi() / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(lat1 * rad) * :math.cos(lat2 * rad) * :math.pow(:math.sin(dlon / 2), 2)

    Float.round(3958.8 * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a)), 1)
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
    |> Enum.reduce(%{}, fn [state, name, population, lat, lon], acc ->
      town = %{
        label: "#{name}, #{state}",
        name: name,
        state: state,
        population: String.to_integer(population),
        lat: String.to_float(lat),
        lon: String.to_float(lon)
      }

      Map.update(acc, state, [town], &[town | &1])
    end)
    |> Map.new(fn {state, towns} -> {state, Enum.reverse(towns)} end)
  end
end
