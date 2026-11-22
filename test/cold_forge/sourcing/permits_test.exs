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

      assert quick.name == "Quick Roofing"
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
      assert soukup.name == "Soukup Roofing"
      assert soukup.raw["contact_name"] == "Joshua Mueller"
    end

    test "the query reads one resource since the cut-off" do
      sql = Permits.san_antonio_sql("abc-123", "roofing", ~D[2026-08-24])

      assert sql =~ ~s|FROM "abc-123"|
      assert sql =~ "'2026-08-24'"
      assert sql =~ ~s|"PERMIT TYPE" ILIKE '%roof%'|
    end
  end

  describe "names as an email would write them" do
    test "initials stay, shouting goes, legal endings go" do
      assert Permits.clean_name("DV ROOFING") == "DV Roofing"
      assert Permits.clean_name("IRC ROOFING & CONSTRUCTION, LLC") == "IRC Roofing & Construction"
      assert Permits.clean_name("BLDT CONTRACTING LLC") == "BLDT Contracting"
      assert Permits.clean_name("TOP ROOFING CO.") == "Top Roofing"
      assert Permits.clean_name("DIAMOND BAR CUSTOM BUILDERS") == "Diamond Bar Custom Builders"

      assert Permits.clean_name("Jolly Roofing and Contracting Co LLC") ==
               "Jolly Roofing and Contracting"

      # "Company" stays: without it this reads as a person.
      assert Permits.clean_name("Gary Werner Company") == "Gary Werner Company"
    end

    test "the trading name when both are given, and the city's notes removed" do
      assert Permits.clean_name("GDM LLC dba Big Tex Construction") == "Big Tex Construction"

      assert Permits.clean_name("CG&S Construction, Inc. dba: CG&S Design-Build") ==
               "CG&S Design-Build"

      assert Permits.clean_name("Design Build Austin Inc(MAIN)") == "Design Build Austin"
      assert Permits.clean_name("37urban Companies (37urban Partners LLC)") == "37urban Companies"
      assert Permits.clean_name("Window Nation LLC**Main**") == "Window Nation"
      assert Permits.clean_name("SHC Remodeling, LLC **MAIN GC**") == "SHC Remodeling"
      assert Permits.clean_name("SAN JUAN PHC AGENCY") == "San Juan PHC Agency"
      assert Permits.clean_name("ROOFING SERVICES NOW") == "Roofing Services Now"
    end

    test "a contractor's key doesn't move when the display name changes" do
      [row] =
        Permits.parse("austin", "roofing", [
          %{"contractor_company_name" => "Quick Roofing LLC", "permits" => "1"}
        ])

      # The key the first run saved, so the next run knows them.
      assert row.source_ref == "austin:quick-roofing"

      [row] =
        Permits.parse("austin", "roofing", [
          %{"contractor_company_name" => "GDM LLC dba Big Tex Construction", "permits" => "1"}
        ])

      assert row.name == "Big Tex Construction"
      assert row.source_ref == "austin:gdm-dba-big-tex-construction"
    end

    test "San Antonio's 30-character cut is undone, and only names that hit it" do
      rows =
        Permits.parse("san_antonio", "roofing", [
          %{"contact" => "ANA GARCIA, GARCIA'S REMODELING & CONSTRUC", "permits" => 3},
          %{"contact" => "BOB SMITH, IRC ROOFING & CONSTRUCTION, LL", "permits" => 9},
          %{"contact" => "TOM LEE, III, VINTAGE RECONSTRUCTION, INC", "permits" => 2}
        ])
        |> Map.new(&{&1.name, &1.raw})

      assert rows["Garcia's Remodeling"]["name_truncated"]
      assert rows["IRC Roofing & Construction"]["name_truncated"]
      assert rows["Vintage Reconstruction"]
      refute rows["Vintage Reconstruction"]["name_truncated"]
    end

    test "a suffix alone, or a person as their own company, is no contractor" do
      assert [] ==
               Permits.parse("san_antonio", "roofing", [
                 %{"contact" => "MIKE HOWELL, JR", "permits" => 2},
                 %{"contact" => "ANN ROE, INC", "permits" => 4}
               ])

      assert [] ==
               Permits.parse("austin", "windows", [
                 %{
                   "contractor_company_name" => "Manohar Bashyam",
                   "contractor_full_name" => "MANOHAR BASHYAM",
                   "permits" => "1"
                 }
               ])
    end

    test "trades the first run let through are left out" do
      names = [
        "True Air",
        "ATX Clima LLC",
        "Mister Sparky Austin",
        "Dobbs Tennis Courts, Inc.",
        "Temperature Pro West Austin",
        "Indoor Comfort Experts A/C",
        "Austin Facility Services",
        "Camacho Flooring",
        "Clean Tag Permits",
        "210 Realty, LLC",
        "Frosty Mist LLC",
        "Infinity Replacement, LLC",
        "SHC Remodeling, LLC, DBA Window World **MAIN GC**"
      ]

      records =
        Enum.map(names, &%{"contractor_company_name" => &1, "permits" => "1"}) ++
          [%{"contractor_company_name" => "Fresh Coat Roofing", "permits" => "1"}]

      assert ["Fresh Coat Roofing"] ==
               "austin" |> Permits.parse("roofing", records) |> Enum.map(& &1.name)
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

    test "the same name in another state is another business" do
      rows = [
        %{name: "Kanga Roof", phone: nil, region: "AZ", website: "https://tucson.test"},
        %{name: "Kanga Roof", phone: nil, region: "TX", website: "https://kangaroof.test"}
      ]

      assert %{website: "https://kangaroof.test"} =
               FindWebsite.pick_match(org(%{phone: nil, region: "TX"}), rows)
    end

    test "a name the city cut short takes the listing's, minus its advertising" do
      cut = org(%{name: "Garcia's Remodeling", raw: %{"name_truncated" => true}})

      match = %{
        name: "Garcia's Remodeling & Construction: San Antonio Remodeler",
        website: "https://garcias.test"
      }

      assert FindWebsite.with_name(cut, match).rename == "Garcia's Remodeling & Construction"

      # A whole name stays as the city wrote it.
      refute Map.has_key?(FindWebsite.with_name(org(%{raw: %{}}), match), :rename)
    end

    test "a one-word name doesn't match every business that starts with it" do
      rows = [%{name: "Summit Dental", phone: nil, website: "https://dental.test"}]
      assert FindWebsite.pick_match(org(%{name: "Summit", phone: nil}), rows) == nil
    end
  end
end
