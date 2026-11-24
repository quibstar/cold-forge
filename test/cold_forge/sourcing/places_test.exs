defmodule ColdForge.Sourcing.Discovery.PlacesTest do
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Discovery.Places

  # The shape Places API (New) searchText returns, with the fields our mask
  # asks for and several it does not — so the test can prove we drop them.
  @response """
  {
    "places": [
      {
        "id": "ChIJrooferGR",
        "displayName": {"text": "Summit Roofing LLC", "languageCode": "en"},
        "formattedAddress": "123 Monroe Ave NW, Grand Rapids, MI 49503, USA",
        "websiteUri": "https://summitroofing.test/",
        "nationalPhoneNumber": "(616) 555-0101",
        "businessStatus": "OPERATIONAL",
        "rating": 4.8,
        "userRatingCount": 212,
        "location": {"latitude": 42.9634, "longitude": -85.6681},
        "regularOpeningHours": {"openNow": true},
        "photos": [{"name": "places/x/photos/y"}]
      },
      {
        "id": "ChIJclosed",
        "displayName": {"text": "Gone Exteriors", "languageCode": "en"},
        "websiteUri": "https://gone.test",
        "businessStatus": "CLOSED_PERMANENTLY"
      },
      {
        "id": "ChIJnoname",
        "websiteUri": "https://anonymous.test"
      },
      {
        "id": "ChIJfacebookonly",
        "displayName": {"text": "Social Only Gutters", "languageCode": "en"},
        "websiteUri": "https://www.facebook.com/socialgutters",
        "businessStatus": "OPERATIONAL"
      }
    ],
    "nextPageToken": "TOKEN123"
  }
  """

  describe "request building" do
    test "asks for the segment's phrase in the locality" do
      assert {:ok, body} = Places.search_body("gutters", "Grand Rapids, MI")
      assert body["textQuery"] == "gutter installation in Grand Rapids, MI"
      assert body["maxResultCount"] == 20
      refute Map.has_key?(body, "pageToken")
    end

    test "carries a page token when continuing" do
      assert {:ok, body} = Places.search_body("roofing", "Holland, MI", page_token: "abc")
      assert body["pageToken"] == "abc"
    end

    test "a trade with no tuned phrases is searched as written" do
      # A new business shouldn't need a code change to look for its customers.
      assert {:ok, body} = Places.search_body("deck builder", "Holland, MI")
      assert body["textQuery"] == "deck builder in Holland, MI"
    end

    test "an empty segment is an error rather than an empty search" do
      assert {:error, {:unknown_segment, ""}} = Places.search_body("", "Holland, MI")
    end

    test "searches the phrase it is asked for, not just the first" do
      # Each built-in segment lists several phrasings; only the first used to
      # run, so the rest were listed and never searched.
      assert {:ok, body} =
               Places.search_body("windows", "Holland, MI", query: "window and door contractor")

      assert body["textQuery"] == "window and door contractor in Holland, MI"
    end

    test "| separates alternative phrasings of one trade" do
      assert Places.queries_for("deck builder | deck contractor") ==
               ["deck builder", "deck contractor"]
    end

    test "covers every segment both products need" do
      for segment <- ~w(roofing siding windows gutters shelter rescue humane_society breeder) do
        assert Places.queries_for(segment) != [], segment
      end
    end
  end

  describe "canonical/1" do
    test "everyday wording lands on the built-in trade" do
      assert Places.canonical("Windows & Doors") == "windows"
      assert Places.canonical(~s("Window & Doors")) == "windows"
      assert Places.canonical("Roofers") == "roofing"
      assert Places.canonical("Gutter") == "gutters"
      assert Places.canonical("Humane Society") == "humane_society"
    end

    test "anything else is kept as written, tidied" do
      assert Places.canonical("  Deck   Builder ") == "deck builder"
      assert Places.canonical("Deck builder|deck contractor") == "deck builder | deck contractor"
      assert Places.canonical("  ") == ""
    end
  end

  describe "the field mask is the cost control" do
    test "asks for exactly the fields we use and nothing billable beyond them" do
      mask = Places.field_mask()

      for field <- ~w(places.id places.displayName places.websiteUri places.nationalPhoneNumber
                      places.primaryType places.types) do
        assert mask =~ field
      end

      # Each of these would raise the SKU, and none of them is kept anyway.
      for costly <- ~w(places.rating places.reviews places.photos places.location
                       places.regularOpeningHours places.priceLevel) do
        refute mask =~ costly, "#{costly} must not be in the mask"
      end
    end
  end

  describe "parsing" do
    test "keeps an operational place and its website" do
      assert {:ok, rows, _token} = Places.parse(@response, "roofing")
      row = Enum.find(rows, &(&1.source_ref == "ChIJrooferGR"))

      assert row.name == "Summit Roofing LLC"
      assert row.segment == "roofing"
      assert row.website == "https://summitroofing.test/"
      assert row.phone == "(616) 555-0101"
      assert row.provider == "places"
      assert row.source_url =~ "place_id:ChIJrooferGR"
    end

    test "splits the address into street, town, state and ZIP" do
      {:ok, rows, _} = Places.parse(@response, "roofing")
      row = Enum.find(rows, &(&1.source_ref == "ChIJrooferGR"))

      assert {row.street, row.city, row.region, row.postal_code} ==
               {"123 Monroe Ave NW", "Grand Rapids", "MI", "49503"}
    end

    test "drops a permanently closed business" do
      {:ok, rows, _} = Places.parse(@response, "roofing")
      refute Enum.find(rows, &(&1.source_ref == "ChIJclosed"))
    end

    test "drops a place with no display name" do
      {:ok, rows, _} = Places.parse(@response, "roofing")
      refute Enum.find(rows, &(&1.source_ref == "ChIJnoname"))
    end

    test "a Facebook page is not the company's own site" do
      {:ok, rows, _} = Places.parse(@response, "gutters")
      row = Enum.find(rows, &(&1.source_ref == "ChIJfacebookonly"))

      assert row, "the business is still discovered"
      refute row.website, "but it has no site of its own to crawl"
    end

    test "returns the page token so a locality can be swept to the end" do
      assert {:ok, _rows, "TOKEN123"} = Places.parse(@response, "roofing")
    end

    # Google's terms permit caching place_id, give lat/long 30 days, and
    # otherwise prohibit caching Places content. The cheapest way to honour
    # that is to never store it, so this is asserted rather than trusted.
    test "keeps nothing the Maps terms restrict" do
      {:ok, rows, _} = Places.parse(@response, "roofing")
      row = Enum.find(rows, &(&1.source_ref == "ChIJrooferGR"))

      for restricted <- ~w(rating userRatingCount location regularOpeningHours photos) do
        refute Map.has_key?(row.raw, restricted), "#{restricted} must not be persisted"
      end

      # No coordinates anywhere on the row, under any spelling.
      refute Map.has_key?(row, :latitude)
      refute Map.has_key?(row, :longitude)
      assert Map.keys(row.raw) |> Enum.sort() == ["business_status", "formatted_address"]
    end

    test "an empty response is empty, not an error" do
      assert {:ok, [], nil} = Places.parse(~s({}), "roofing")
    end

    test "malformed json is an error" do
      assert {:error, {:invalid_json, _}} = Places.parse("{nope", "roofing")
    end
  end

  # Every name and type here is one that came back from an "animal shelter"
  # search and was emailed as a shelter before this check existed.
  @neighbours """
  {
    "places": [
      {"id": "ChIJshelter", "displayName": {"text": "Polk County Animal Shelter"},
       "formattedAddress": "5850 Brannen Rd S, Lakeland, FL 33813, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "local_government_office"},
      {"id": "ChIJrescuecare", "displayName": {"text": "Lone Star Pawz Animal Rescue"},
       "formattedAddress": "1 Main St, Pearland, TX 77581, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "pet_care"},
      {"id": "ChIJnotype", "displayName": {"text": "Muttville"},
       "formattedAddress": "255 Alabama St, San Francisco, CA 94103, USA",
       "businessStatus": "OPERATIONAL"},
      {"id": "ChIJgroomer", "displayName": {"text": "Pawradise Estero"},
       "formattedAddress": "1 Main St, Estero, FL 33928, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "pet_care"},
      {"id": "ChIJkennel", "displayName": {"text": "A to Z Dog Ranch, LLC"},
       "formattedAddress": "1 Main St, Conroe, TX 77301, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "pet_boarding_service"},
      {"id": "ChIJvet", "displayName": {"text": "Animal Care Hospital"},
       "formattedAddress": "1 Main St, Erie, PA 16501, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "veterinary_care"},
      {"id": "ChIJgifts", "displayName": {"text": "Purr Haus"},
       "formattedAddress": "1 Main St, Allentown, PA 18101, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "gift_shop"},
      {"id": "ChIJfire", "displayName": {"text": "Key Biscayne Fire Rescue Department"},
       "formattedAddress": "560 Crandon Blvd, Key Biscayne, FL 33149, USA",
       "businessStatus": "OPERATIONAL"},
      {"id": "ChIJsar", "displayName": {"text": "Peace River K9 Search and Rescue, Inc."},
       "formattedAddress": "1 Main St, Arcadia, FL 34266, USA",
       "businessStatus": "OPERATIONAL", "primaryType": "non_profit_organization"},
      {"id": "ChIJhomeless", "displayName": {"text": "Open Arms Shelter & Social Services"},
       "formattedAddress": "1 Main St, Yonkers, NY 10701, USA",
       "businessStatus": "OPERATIONAL"}
    ]
  }
  """

  defp refs(segment, opts \\ []) do
    {:ok, rows, _} = Places.parse(@neighbours, segment, opts)
    rows |> Enum.map(& &1.source_ref) |> Enum.sort()
  end

  describe "a shelter search keeps shelters" do
    test "drops the groomer, kennel, vet, gift shop, fire department, search team and homeless shelter" do
      assert refs("shelter") == ["ChIJnotype", "ChIJrescuecare", "ChIJshelter"]
      assert refs("rescue") == refs("shelter")
      assert refs("humane_society") == refs("shelter")
    end

    test "a rescue that Google files as pet care is still a rescue" do
      assert "ChIJrescuecare" in refs("shelter")
    end

    test "a place Google gives no type is judged by its name alone" do
      assert "ChIJnotype" in refs("shelter")
      refute "ChIJfire" in refs("shelter")
    end

    test "trades are not filtered by kind" do
      assert length(refs("roofing")) == 10
    end

    test "a breeder search drops the vet and the gift shop but keeps kennels" do
      breeder = refs("dog breeder")

      assert "ChIJkennel" in breeder
      refute "ChIJvet" in breeder
      refute "ChIJgifts" in breeder
      refute "ChIJfire" in breeder
    end
  end

  describe "a search keeps to its town's state" do
    test "drops a result from another state" do
      assert refs("roofing", locality: "Lakeland, FL") ==
               ["ChIJfire", "ChIJgroomer", "ChIJsar", "ChIJshelter"]
    end

    test "a bare state works the same as a town in it" do
      assert refs("roofing", locality: "Florida") == refs("roofing", locality: "Lakeland, FL")
      assert refs("roofing", locality: "FL") == refs("roofing", locality: "Florida")
    end

    test "a locality with no state checks nothing" do
      assert length(refs("roofing", locality: "Coral Gables")) == 10
    end

    test "a result with no readable state is kept" do
      {:ok, rows, _} =
        Places.parse(
          %{"places" => [%{"id" => "x", "displayName" => %{"text" => "Somewhere Rescue"}}]},
          "shelter",
          locality: "Lakeland, FL"
        )

      assert [%{source_ref: "x"}] = rows
    end
  end

  describe "locality_region/1" do
    test "reads the state from a town, a state name or a code" do
      assert Places.locality_region("Coral Gables, FL") == "FL"
      assert Places.locality_region("Florida") == "FL"
      assert Places.locality_region("ny") == "NY"
      assert Places.locality_region("Coral Gables") == nil
      assert Places.locality_region(nil) == nil
    end
  end

  describe "split_address/1" do
    test "keeps a suite with the street, and a ZIP+4 as the ZIP" do
      assert Places.split_address("123 Main St, Ste 4, Holland, MI 49423-1234, USA") ==
               %{
                 street: "123 Main St, Ste 4",
                 city: "Holland",
                 region: "MI",
                 postal_code: "49423"
               }
    end

    test "a town with no street is still a town" do
      assert %{street: nil, city: "Holland", region: "MI"} =
               Places.split_address("Holland, MI, USA")
    end

    test "anything else is nothing rather than a guess" do
      empty = %{street: nil, city: nil, region: nil, postal_code: nil}
      assert Places.split_address("Somewhere vague") == empty
      assert Places.split_address(nil) == empty
    end
  end
end
