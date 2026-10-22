defmodule ColdForge.FlyersTest do
  @moduledoc """
  Flyers: what they say, where they go, and the scan that comes back. The
  load-bearing rule is that a printed flyer's QR keeps working — so a place is
  never deleted once it could be on a board.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Flyers, Repo}
  alias ColdForge.Flyers.Content
  alias ColdForge.Sourcing.{Org, Source}

  setup do
    project = project_fixture(name: "ExteriorPro")

    {:ok, project} =
      Flyers.update_content(project, %{
        "url" => "https://exteriorpro.io/pro",
        "eyebrow" => "For exterior contractors",
        "trade_eyebrow" => "For {{trade}} contractors",
        "headline" => "Run the job.\nNot the paperwork.",
        "steps" => "Lead comes in — call or web form\nA plain line"
      })

    %{project: project}
  end

  defp org(project, attrs, purpose \\ "flyers") do
    source =
      Repo.insert!(%Source{
        name: "Supply houses #{System.unique_integer([:positive])}",
        project_id: project.id,
        purpose: purpose,
        provider: "places",
        segments: ["roofing supply"],
        localities: ["Michigan"]
      })

    Repo.insert!(
      struct(
        %Org{
          source_id: source.id,
          provider: "places",
          source_ref: "ref-#{System.unique_integer([:positive])}",
          segment: "roofing supply"
        },
        attrs
      )
    )
  end

  describe "content" do
    test "saves on the project without touching its other settings", %{project: project} do
      project = Repo.reload(project)
      assert Flyers.content(project).headline == "Run the job.\nNot the paperwork."
      assert project.from_email
    end

    test "needs a landing URL and a headline", %{project: project} do
      assert {:error, _} = Flyers.update_content(project, %{"url" => "exteriorpro.io/pro"})
    end

    test "prints the URL without its scheme" do
      assert Content.display_url(%Content{url: "https://exteriorpro.io/pro/"}) ==
               "exteriorpro.io/pro"
    end

    test "a trade swaps in the trade eyebrow", %{project: project} do
      content = Flyers.content(project)
      assert Content.eyebrow(content, "roofing") == "For roofing contractors"
      assert Content.eyebrow(content, nil) == "For exterior contractors"
    end

    test "bolds the part of a point before the dash", %{project: project} do
      assert Content.steps(Flyers.content(project)) ==
               [{"Lead comes in", " — call or web form"}, {nil, "A plain line"}]
    end
  end

  describe "codes" do
    test "come from the name and town, and stay unique", %{project: project} do
      {:ok, a} =
        Flyers.create_placement(project, %{venue_name: "ABC Supply Co.", address: "Wyoming, MI"})

      {:ok, b} =
        Flyers.create_placement(project, %{venue_name: "ABC Supply Co.", address: "Wyoming, MI"})

      assert a.code == "abc-supply-co-wyoming"
      assert b.code == "abc-supply-co-wyoming-2"
    end

    test "take the town from a full address, not the street", %{project: project} do
      {:ok, p} =
        Flyers.create_placement(project, %{
          venue_name: "ABC Supply",
          address: "2950 Prairie St SW, Wyoming, MI 49509"
        })

      assert p.code == "abc-supply-wyoming"

      {:ok, p} =
        Flyers.create_placement(project, %{venue_name: "Beacon", address: "Grand Rapids"})

      assert p.code == "beacon-grand-rapids"
    end

    test "a hand-picked code must be URL-safe", %{project: project} do
      assert {:error, cs} =
               Flyers.create_placement(project, %{venue_name: "X", code: "Not OK!"})

      assert errors_on(cs).code != []
    end
  end

  describe "adding from sourcing" do
    test "adds what a search found, once", %{project: project} do
      found = org(project, %{name: "Beacon Roofing Supply", city: "Grand Rapids", region: "MI"})

      assert [%{id: id}] = Flyers.candidate_orgs(project.id, found.source_id)
      assert id == found.id

      assert Flyers.add_orgs(project, [found.id]) == 1
      assert [placement] = Flyers.list_placements(project.id)
      assert placement.org_id == found.id
      assert placement.code == "beacon-roofing-supply-grand-rapids"
      assert placement.address =~ "Grand Rapids, MI"

      # Already placed, so no longer offered — and adding again does nothing.
      assert Flyers.candidate_orgs(project.id, found.source_id) == []
      assert Flyers.add_orgs(project, [found.id]) == 0
    end

    test "only offers the one search chosen, never the contractor list beside it",
         %{project: project} do
      supply = org(project, %{name: "ABC Supply"})
      contractor = org(project, %{name: "Above Roofing"})

      assert Enum.map(Flyers.candidate_orgs(project.id, supply.source_id), & &1.name) ==
               ["ABC Supply"]

      refute contractor.source_id == supply.source_id
      assert Flyers.candidate_orgs(project.id, nil) == []
    end

    test "never offers a prospect search, even when chosen", %{project: project} do
      roofer = org(project, %{name: "Above Roofing"}, "prospects")

      assert Flyers.candidate_orgs(project.id, roofer.source_id) == []
      assert Flyers.add_orgs(project, [roofer.id]) == 0
    end

    test "won't add another project's results", %{project: project} do
      elsewhere = org(project_fixture(name: "Other"), %{name: "Elsewhere Supply"})

      assert Flyers.candidate_orgs(project.id, elsewhere.source_id) == []
      assert Flyers.add_orgs(project, [elsewhere.id]) == 0
    end
  end

  describe "scans" do
    setup %{project: project} do
      {:ok, placement} =
        Flyers.create_placement(project, %{
          venue_name: "ABC Supply",
          address: "Wyoming, MI",
          trade: "Roofing"
        })

      %{placement: placement}
    end

    test "count against the place and keep the landing page's own query", %{placement: placement} do
      {:ok, scanned} = Flyers.record_scan(placement.code, "iPhone")

      assert Repo.reload(placement).scans_count == 1
      assert Repo.reload(placement).last_scanned_at

      uri = URI.parse(Flyers.destination_url(scanned))
      assert uri.host == "exteriorpro.io"
      assert uri.path == "/pro"
      assert URI.decode_query(uri.query) == %{"s" => placement.code, "t" => "roofing"}
    end

    test "an unknown code is an error, not a guess", _ctx do
      assert Flyers.record_scan("no-such-flyer") == :error
    end

    test "a flyer taken down still redirects but isn't counted", %{placement: placement} do
      {:ok, placement} = Flyers.update_placement(placement, %{status: "removed"})

      assert {:ok, _} = Flyers.record_scan(placement.code)
      assert Repo.reload(placement).scans_count == 0
    end

    test "the QR encodes our own redirect, so the scan is counted first", %{placement: placement} do
      assert Flyers.scan_url(placement) =~ "/f/#{placement.code}"
      svg = Flyers.qr_svg(placement)
      assert svg =~ ~s(<svg class="qr")
      refute svg =~ "<?xml"
    end
  end

  describe "deleting" do
    test "only a place never put up and never scanned", %{project: project} do
      {:ok, fresh} = Flyers.create_placement(project, %{venue_name: "Fresh"})
      assert {:ok, _} = Flyers.delete_placement(fresh)

      {:ok, up} = Flyers.create_placement(project, %{venue_name: "Up"})
      {:ok, up} = Flyers.update_placement(up, %{status: "posted"})
      assert {:error, :printed} = Flyers.delete_placement(up)

      {:ok, scanned} = Flyers.create_placement(project, %{venue_name: "Scanned"})
      {:ok, _} = Flyers.record_scan(scanned.code)
      assert {:error, :printed} = Flyers.delete_placement(Repo.reload(scanned))
    end
  end
end
