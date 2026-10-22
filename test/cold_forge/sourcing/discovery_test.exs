defmodule ColdForge.Sourcing.DiscoveryTest do
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Discovery.{IrsBmf, LicenseCsv, Overpass}
  alias ColdForge.Sourcing.Org

  @overpass_fixture "test/support/fixtures/sourcing/overpass_shelters_mi.json"

  describe "Overpass query building" do
    test "asks for the tags a segment maps to, inside the state's area" do
      query = Overpass.query(["roofing", "shelter"], "US-MI")

      assert query =~ ~s|area["ISO3166-2"="US-MI"]|
      assert query =~ ~s|nwr["craft"="roofer"](area.region);|
      assert query =~ ~s|nwr["amenity"="animal_shelter"](area.region);|
      assert query =~ "out center tags;"
    end

    test "an unknown segment contributes nothing rather than breaking the query" do
      assert Overpass.query(["not_a_segment"], "US-MI") =~ "area["
    end
  end

  describe "Overpass parsing, against a real Michigan response" do
    setup do
      %{json: File.read!(@overpass_fixture)}
    end

    test "keeps the named elements and drops the rest", %{json: json} do
      assert {:ok, rows} = Overpass.parse(json, "shelter")

      # 35 elements came back; 29 carry a name. An unnamed building is not an
      # organisation anyone can write to.
      assert length(rows) == 29
      assert Enum.all?(rows, &is_binary(&1.name))
    end

    test "splits humane societies and rescues out of the shelter query", %{json: json} do
      {:ok, rows} = Overpass.parse(json, "shelter")
      by_segment = Enum.frequencies_by(rows, & &1.segment)

      assert by_segment["humane_society"] > 0
      assert by_segment["rescue"] > 0
      assert by_segment["shelter"] > 0

      assert Enum.find(rows, &(&1.name == "Michigan Humane Society")).segment == "humane_society"
      assert Enum.find(rows, &(&1.name == "Michigan Animal Rescue League")).segment == "rescue"
    end

    test "records a traceable source for every row", %{json: json} do
      {:ok, rows} = Overpass.parse(json, "shelter")

      for row <- rows do
        assert row.source == "overpass"
        assert row.source_ref =~ ~r"^(node|way|relation)/\d+$"
        assert row.source_url =~ "openstreetmap.org/"
      end
    end

    test "most rows have no website, which is the point of measuring", %{json: json} do
      {:ok, rows} = Overpass.parse(json, "shelter")
      with_site = Enum.count(rows, & &1.website)

      # Nine of the 35 elements carry one. Coverage this thin is why Overpass
      # is a seed rather than the engine.
      assert with_site == 9
      assert with_site < length(rows) / 2
    end

    test "an OSM email tag is kept as raw data, never promoted to the row" do
      json = """
      {"elements":[{"type":"node","id":1,"tags":{
        "name":"Somewhere Rescue","email":"someone@rescue.test","amenity":"animal_shelter"}}]}
      """

      assert {:ok, [row]} = Overpass.parse(json, "shelter")
      refute Map.has_key?(row, :email)
      assert row.raw["email"] == "someone@rescue.test"
    end

    test "a social page in the website field is not their own site" do
      json = """
      {"elements":[{"type":"node","id":2,"tags":{
        "name":"Facebook Only Rescue","website":"https://facebook.com/pages/x"}}]}
      """

      assert {:ok, [row]} = Overpass.parse(json, "shelter")
      refute row.website
    end

    test "malformed json is an error, not an empty list" do
      assert {:error, {:invalid_json, _}} = Overpass.parse("{not json", "shelter")
      assert {:error, :unexpected_shape} = Overpass.parse(~s({"nope":1}), "shelter")
    end
  end

  describe "IRS Business Master File" do
    @header "EIN,NAME,STREET,CITY,STATE,ZIP,SUBSECTION,NTEE_CD"

    defp bmf(rows), do: Enum.join([@header | rows], "\n")

    test "keeps D20 and drops everything else" do
      csv =
        bmf([
          "381234567,HUMANE SOCIETY OF WEST MICHIGAN,3077 WILSON DR NW,GRAND RAPIDS,MI,49534-1234,03,D20",
          "382222222,GRAND RAPIDS SYMPHONY,300 OTTAWA AVE,GRAND RAPIDS,MI,49503,03,A69",
          "383333333,SOME BIRD SANCTUARY,1 WAY,HOLLAND,MI,49423,03,D30"
        ])

      assert {:ok, [row]} = IrsBmf.parse(csv)
      assert row.name == "Humane Society of West Michigan"
      assert row.segment == "humane_society"
      assert row.source == "irs_bmf"
      assert row.source_ref == "381234567"
    end

    test "filters by state when asked" do
      csv =
        bmf([
          "381111111,KENT COUNTY ANIMAL SHELTER,740 FULLER AVE NE,GRAND RAPIDS,MI,49503,03,D20",
          "061111111,SOME OHIO SHELTER,1 MAIN ST,TOLEDO,OH,43604,03,D20"
        ])

      assert {:ok, rows} = IrsBmf.parse(csv, states: ["MI"])
      assert [%{region: "MI"}] = rows
    end

    test "cases the shouting names the IRS publishes" do
      csv = bmf(["381111111,SPCA OF SOUTHWEST MICHIGAN,6955 W KL AVE,KALAMAZOO,MI,49009,03,D20"])

      assert {:ok, [row]} = IrsBmf.parse(csv)
      # SPCA is an initialism and stays; "of" stays lowercase.
      assert row.name == "SPCA of Southwest Michigan"
      assert row.city == "Kalamazoo"
    end

    test "a name that is already mixed case is left alone" do
      csv = bmf(["381111111,Crash's Landing,3433 River Hill Dr NW,GRAND RAPIDS,MI,49534,03,D20"])

      assert {:ok, [row]} = IrsBmf.parse(csv)
      assert row.name == "Crash's Landing"
    end

    test "trims ZIP+4 and carries no website, so the row needs one resolved" do
      csv = bmf(["381111111,A RESCUE,1 MAIN ST,HOLLAND,MI,49423-0144,03,D20"])

      assert {:ok, [row]} = IrsBmf.parse(csv)
      assert row.postal_code == "49423"
      refute row.website
      # Which is what sends it down the needs_website path:
      changeset = Org.discovery_changeset(%Org{}, row)
      assert Ecto.Changeset.get_field(changeset, :status) == "needs_website"
    end

    test "a file without the columns we need is an error" do
      assert {:error, {:missing_columns, missing}} = IrsBmf.parse("FOO,BAR\n1,2")
      assert "EIN" in missing and "NAME" in missing
    end
  end

  describe "state licence registries" do
    @mapping %{
      source_name: "mi_lara",
      region: "MI",
      source_url: "https://www.michigan.gov/lara",
      columns: %{
        name: "BUSINESS NAME",
        city: "CITY",
        license: "LICENSE NUMBER",
        website: "WEB SITE"
      },
      segment_column: "SPECIALTY",
      segment_rules: [{"roof", "roofing"}, {"siding", "siding"}, {"gutter", "gutters"}]
    }

    test "maps their columns onto ours and resolves the segment" do
      csv = """
      LICENSE NUMBER,BUSINESS NAME,CITY,SPECIALTY,WEB SITE
      2101000001,Summit Roofing LLC,Grand Rapids,Roofing & Sheet Metal,summitroofing.test
      """

      assert {:ok, [row]} = LicenseCsv.parse(csv, @mapping)
      assert row.name == "Summit Roofing LLC"
      assert row.segment == "roofing"
      assert row.region == "MI"
      assert row.website == "https://summitroofing.test"
      assert row.source_ref == "mi_lara:2101000001"
      assert row.raw["registry"] == "mi_lara"
    end

    test "a row whose trade matches no rule is dropped" do
      csv = """
      LICENSE NUMBER,BUSINESS NAME,CITY,SPECIALTY,WEB SITE
      2101000002,Jones Plumbing,Holland,Plumbing,
      """

      assert {:ok, []} = LicenseCsv.parse(csv, @mapping)
    end

    test "one row per trade endorsement collapses to one prospect" do
      csv = """
      LICENSE NUMBER,BUSINESS NAME,CITY,SPECIALTY,WEB SITE
      2101000003,Lakeshore Exteriors,Holland,Roofing,lakeshore.test
      2101000003,Lakeshore Exteriors,Holland,Roofing & Gutters,lakeshore.test
      """

      assert {:ok, rows} = LicenseCsv.parse(csv, @mapping)
      assert length(rows) == 1
    end

    test "headers survive a BOM and stray spacing" do
      csv = "﻿ LICENSE NUMBER , BUSINESS NAME ,CITY,SPECIALTY,WEB SITE\n1,A Co,Holland,Roofing,\n"

      assert {:ok, [row]} = LicenseCsv.parse(csv, @mapping)
      assert row.name == "A Co"
    end

    test "without a licence number the key still identifies the row" do
      mapping = Map.put(@mapping, :columns, %{name: "BUSINESS NAME", city: "CITY"})

      csv = "BUSINESS NAME,CITY,SPECIALTY\nVriesland Siding,Zeeland,Siding\n"

      assert {:ok, [row]} = LicenseCsv.parse(csv, mapping)
      assert row.source_ref == "mi_lara:vriesland-siding:zeeland"
    end

    test "a mapping naming a column the file lacks is an error, not silence" do
      csv = "NAME,CITY\nA Co,Holland\n"
      assert {:error, {:missing_columns, _}} = LicenseCsv.parse(csv, @mapping)
    end

    test "a mapping without a name column is refused" do
      assert {:error, :mapping_needs_source_name_and_name_column} =
               LicenseCsv.parse("A,B\n1,2", %{source_name: "x", columns: %{}})
    end
  end
end
