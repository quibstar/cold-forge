defmodule ColdForge.Sourcing.Discovery.Overpass do
  @moduledoc """
  OpenStreetMap, through the Overpass API.

  Free, openly licensed (ODbL), and the tags are clean when they exist. The
  catch is coverage: a probe for Michigan returned **95 exterior trades** (50
  roofers, 35 window firms, no gutter installers at all) and **35 animal
  shelters**. Against the roughly 700-900 roofing establishments Michigan
  actually has, that is on the order of 6%.

  So this is a seed, not an engine. What it returns is accurate and about half
  of it carries a website, which is worth having — but a plan that depends on
  Overpass for volume will quietly cap out. The public endpoint also says
  plainly that it is meant for human-operated tools, and it answered one of our
  two probe queries with a 502 "at capacity", so it is rate-limited by
  intention as well as by politeness.
  """

  alias ColdForge.Sourcing.Org

  @endpoint "https://overpass-api.de/api/interpreter"

  # OSM's craft/amenity tags, by what we call the segment. Gutter installers
  # have a tag but, in Michigan at least, nobody uses it.
  @tags %{
    "roofing" => [~s(nwr["craft"="roofer"])],
    "windows" => [~s(nwr["craft"="window_construction"])],
    "gutters" => [~s(nwr["craft"="gutter_installer"])],
    "siding" => [~s(nwr["craft"="plasterer"]), ~s(nwr["craft"="carpenter"])],
    "shelter" => [
      ~s(nwr["amenity"="animal_shelter"]),
      ~s(nwr["amenity"="animal_boarding"]["animal_shelter"])
    ]
  }

  def endpoint, do: @endpoint
  def segments, do: Map.keys(@tags)

  @doc """
  The Overpass QL for some segments in one US state, by ISO code ("US-MI").
  """
  @spec query([String.t()], String.t()) :: String.t()
  def query(segments, iso_region) when is_list(segments) do
    clauses =
      segments
      |> Enum.flat_map(&Map.get(@tags, &1, []))
      |> Enum.map_join("\n  ", &"#{&1}(area.region);")

    """
    [out:json][timeout:90];
    area["ISO3166-2"="#{iso_region}"][admin_level=4]->.region;
    (
      #{clauses}
    );
    out center tags;
    """
  end

  @doc """
  Turns an Overpass JSON response into rows for `Sourcing.Org`.

  Pure, so it is tested against a saved response rather than the live API.
  Elements with no name are dropped: an unnamed building is not an
  organisation anyone can write to.
  """
  @spec parse(String.t() | map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(json, segment) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> parse(decoded, segment)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  def parse(%{"elements" => elements}, segment) when is_list(elements) do
    {:ok, elements |> Enum.map(&element_to_attrs(&1, segment)) |> Enum.reject(&is_nil/1)}
  end

  def parse(_other, _segment), do: {:error, :unexpected_shape}

  defp element_to_attrs(%{"type" => type, "id" => id} = element, segment) do
    tags = Map.get(element, "tags") || %{}

    case tags |> Map.get("name") |> presence() do
      nil ->
        nil

      name ->
        %{
          name: name,
          segment: segment_for(segment, name),
          website:
            Org.normalize_website(tags["website"] || tags["contact:website"] || tags["url"]),
          phone: presence(tags["phone"] || tags["contact:phone"]),
          street: street(tags),
          city: presence(tags["addr:city"]),
          region: presence(tags["addr:state"]),
          postal_code: presence(tags["addr:postcode"]),
          country: "US",
          provider: "overpass",
          source_ref: "#{type}/#{id}",
          source_url: "https://www.openstreetmap.org/#{type}/#{id}",
          raw: tags
        }
    end
  end

  defp element_to_attrs(_element, _segment), do: nil

  # OSM carries an email tag now and then. We deliberately don't take it as the
  # prospect's address: the rule is that an address comes off the
  # organisation's own page, with that page recorded. A third party's database
  # saying so is how you end up unable to explain a row. It stays in `raw`.
  defp street(tags) do
    [tags["addr:housenumber"], tags["addr:street"]]
    |> Enum.reject(&(presence(&1) == nil))
    |> Enum.join(" ")
    |> presence()
  end

  # A shelter query turns up humane societies and breed rescues alike, and they
  # get different cadences. The name is the only signal OSM gives.
  defp segment_for("shelter", name) do
    down = String.downcase(name)

    cond do
      String.contains?(down, "humane") -> "humane_society"
      String.contains?(down, "rescue") -> "rescue"
      true -> "shelter"
    end
  end

  defp segment_for(segment, _name), do: segment

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
