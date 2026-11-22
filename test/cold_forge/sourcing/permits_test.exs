defmodule ColdForge.Sourcing.PermitsTest do
  @moduledoc """
  City permit feeds: one row per contractor, the ones who aren't an exterior
  shop left out, and nothing about the homeowner kept.
  """
  use ExUnit.Case, async: true

  alias ColdForge.Sourcing.Discovery.Permits
  alias ColdForge.Workers.FindWebsite
  alias ColdForge.Sourcing.Org

  describe "Austin" do
    test "one row per contractor, the permits added up and the busiest phone kept" do
      records = [
        %{
          "contractor_company_name" => "QUICK ROOFING LLC",
          "contractor_full_name" => "JASON ARMSTRONG",
          "contractor_phone" => "8174770999",
          "contractor_city" => "AUSTIN",
          "permits" => "9",
          "last_issued" => "2026-11-04T00:00:00.000"
        },
        %{
          "contractor_company_name" => "Quick Roofing, LLC",
          "contractor_full_name" => "Jason Armstrong",
          "contractor_phone" => "817-477-0999",
          "contractor_city" => "Austin",
          "permits" => "3",
          "last_issued" => "2026-10-01T00:00:00.000"
        },
        %{
          "contractor_company_name" => "Kanga Roof LLC",
          "contractor_full_name" => "Stacie Feller",
          "contractor_phone" => "5123887663",
          "contractor_city" => "AUSTIN",
          "permits" => "7",
          "last_issued" => "2026-11-06T00:00:00.000"
        }
      ]

      [quick, kanga] = Permits.parse("austin", "roofing", records)

      assert quick.name == "Quick Roofing LLC"
      assert quick.phone == "(817) 477-0999"
      assert quick.provider == "permits"
      assert quick.source_ref == "austin:quick-roofing"
      assert quick.region == "TX"

      assert quick.raw == %{
               "permit_city" => "Austin",
               "permits" => 12,
               "last_issued" => "2026-11-04",
               "contact_name" => "Jason Armstrong"
             }

      assert kanga.source_ref == "austin:kanga-roof"
    end

    test "national chains, other trades and blank contractors are left out" do
      names = [
        "Renewal by Andersen",
        "PWD-Austin, LLC (d/b/a or registered trade name) Pella Windows & Doors of Austin",
        "Home Depot USA Inc",
        "Freedom Solar Power",
        "H&M PLUMBING",
        "Owner Builder",
        nil
      ]

      records =
        Enum.map(names, &%{"contractor_company_name" => &1, "permits" => "4"}) ++
          [%{"contractor_company_name" => "Capella Roofing", "permits" => "1"}]

      assert ["Capella Roofing"] ==
               "austin" |> Permits.parse("windows", records) |> Enum.map(& &1.name)
    end

    test "asks for the trade's permits since the cut-off, counted per contractor" do
      params = Permits.austin_params("siding", ~D[2026-08-24])

      assert params[:"$where"] =~ "issue_date >= '2026-08-24'"
      assert params[:"$where"] =~ "SIDING"
      assert params[:"$group"] =~ "contractor_company_name"
    end
  end

  describe "San Antonio" do
    test "takes the company after the contact's name, and skips a bare name" do
      records = [
        %{
          "contact" => "Misti White, Rhino Roofers",
          "permits" => 73,
          "last_issued" => "2026-11-20"
        },
        %{"contact" => "JOSHUA MUELLER, SOUKUP ROOFING,LLC", "permits" => 12},
        # Could as easily be the homeowner, and there's nothing to look up.
        %{"contact" => "Keven Uzun", "permits" => 62},
        %{"contact" => nil, "permits" => 49}
      ]

      [rhino, soukup] = Permits.parse("san_antonio", "roofing", records)

      assert rhino.name == "Rhino Roofers"
      assert rhino.raw["contact_name"] == "Misti White"
      assert rhino.raw["permits"] == 73
      assert rhino.phone == nil
      assert soukup.name == "Soukup Roofing, LLC"
      assert soukup.raw["contact_name"] == "Joshua Mueller"
    end

    test "the query reads one resource since the cut-off" do
      sql = Permits.san_antonio_sql("abc-123", "roofing", ~D[2026-08-24])

      assert sql =~ ~s|FROM "abc-123"|
      assert sql =~ "'2026-08-24'"
      assert sql =~ ~s|"PERMIT TYPE" ILIKE '%roof%'|
    end
  end

  test "an unknown city or trade is an error, not a request" do
    assert {:error, {:unknown_city, "dallas"}} = Permits.fetch("dallas", "roofing")
    assert {:error, {:unknown_segment, "decks"}} = Permits.fetch("austin", "decks")
  end

  describe "matching a Places result to a permit contractor" do
    defp org(attrs),
      do: struct(Org, Map.merge(%{name: "Kanga Roof LLC", phone: "(512) 388-7663"}, attrs))

    test "the same phone is the same shop, whatever the listing is called" do
      rows = [
        %{name: "Someone Else Roofing", phone: "(512) 555-0100", website: "https://else.test"},
        %{name: "Kanga Roof Austin", phone: "+1 512-388-7663", website: "https://kangaroof.test"}
      ]

      assert %{website: "https://kangaroof.test"} = FindWebsite.pick_match(org(%{}), rows)
    end

    test "the same name, minus LLC and punctuation, without a phone" do
      rows = [%{name: "Kanga Roof, L.L.C.", phone: nil, website: "https://kangaroof.test"}]

      assert %{website: "https://kangaroof.test"} =
               FindWebsite.pick_match(org(%{phone: nil}), rows)
    end

    test "a longer name that starts with theirs is the same shop" do
      rows = [%{name: "Kanga Roof and Restoration", phone: nil, website: "https://kanga.test"}]
      assert FindWebsite.pick_match(org(%{phone: nil}), rows)
    end

    test "a different business, or one with no website, is no match" do
      rows = [
        %{name: "Kangaroo Pest Control", phone: "(512) 555-0199", website: "https://pest.test"},
        %{name: "Kanga Roof LLC", phone: "(512) 388-7663", website: nil}
      ]

      assert FindWebsite.pick_match(org(%{}), rows) == nil
    end

    test "a one-word name doesn't match every business that starts with it" do
      rows = [%{name: "Summit Dental", phone: nil, website: "https://dental.test"}]
      assert FindWebsite.pick_match(org(%{name: "Summit", phone: nil}), rows) == nil
    end
  end
end
