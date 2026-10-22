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

    test "an unknown segment is an error rather than an empty search" do
      assert {:error, {:unknown_segment, "plumbing"}} =
               Places.search_body("plumbing", "Grand Rapids, MI")
    end

    test "covers every segment both products need" do
      for segment <- ~w(roofing siding windows gutters shelter rescue humane_society breeder) do
        assert Places.queries_for(segment) != [], segment
      end
    end
  end

  describe "the field mask is the cost control" do
    test "asks for exactly the fields we use and nothing billable beyond them" do
      mask = Places.field_mask()

      for field <- ~w(places.id places.displayName places.websiteUri places.nationalPhoneNumber) do
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
end
