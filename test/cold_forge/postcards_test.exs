defmodule ColdForge.PostcardsTest do
  @moduledoc """
  Postcards: who gets one, the scan that comes back, and the list a mailing
  service needs. The rules that matter are one card per company, nobody who
  asked not to be contacted, and a mailed card's QR that keeps working.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Flyers, Outreach, Postcards, Repo}
  alias ColdForge.Flyers.Content
  alias ColdForge.Sourcing.{Org, Source}

  setup do
    project = project_fixture(name: "ExteriorPro")

    {:ok, project} =
      Flyers.update_content(project, %{
        "url" => "https://exteriorpro.io/pro",
        "headline" => "Run the job.\nNot the paperwork."
      })

    source =
      Repo.insert!(%Source{
        name: "Roofers",
        project_id: project.id,
        provider: "places",
        segments: ["roofing contractor"],
        localities: ["Michigan"]
      })

    %{project: project, source: source}
  end

  # A prospect found by a search, with the address its search record holds.
  defp found(ctx, attrs \\ %{}, org_attrs \\ %{}) do
    prospect =
      prospect_fixture(
        ctx.project,
        Enum.into(attrs, %{
          company: "Herbert Roofing #{System.unique_integer([:positive])}",
          industry: "roofing"
        })
      )

    Repo.insert!(
      struct(
        %Org{
          source_id: ctx.source.id,
          provider: "places",
          source_ref: "ref-#{System.unique_integer([:positive])}",
          segment: "roofing contractor",
          name: prospect.company,
          street: "#{System.unique_integer([:positive])} Main St",
          city: "Grand Rapids",
          region: "MI",
          postal_code: "49503",
          prospect_id: prospect.id
        },
        org_attrs
      )
    )

    prospect
  end

  describe "who can get one" do
    test "prospects with a full street address", ctx do
      with_address = found(ctx)
      _no_zip = found(ctx, %{}, %{postal_code: nil})
      _imported = prospect_fixture(ctx.project, %{company: "From a CSV"})

      assert [{p, _org}] = Postcards.candidates(ctx.project.id)
      assert p.id == with_address.id
    end

    test "leaves out the unsubscribed, the replied, and anyone with a card", ctx do
      carded = found(ctx)
      unsubscribed = found(ctx)
      keep = found(ctx)
      {:ok, _} = Outreach.unsubscribe_prospect(unsubscribed)

      Postcards.add_cards(
        ctx.project,
        Enum.filter(Postcards.candidates(ctx.project.id), fn {p, _} -> p.id == carded.id end)
      )

      assert Enum.map(Postcards.candidates(ctx.project.id), fn {p, _} -> p.id end) == [keep.id]
    end

    test "one card per company address", ctx do
      found(ctx, %{company: "Tittle Brothers"}, %{street: "1 Plaza Dr"})
      found(ctx, %{company: "Tittle Brothers"}, %{street: "1 Plaza Dr"})

      assert length(Postcards.candidates(ctx.project.id)) == 1
    end

    test "filters to phone-only, a trade and a town", ctx do
      phone = found(ctx, %{email: nil, phone: "616-555-0100"})
      _emailed = found(ctx)
      _siding = found(ctx, %{email: nil, phone: "616-555-0101", industry: "siding"})
      _elsewhere = found(ctx, %{email: nil, phone: "616-555-0102"}, %{city: "Detroit"})

      assert [{p, _}] =
               Postcards.candidates(ctx.project.id, %{
                 reach: "phone",
                 trade: "roofing",
                 city: "grand"
               })

      assert p.id == phone.id
    end
  end

  describe "cards" do
    test "copy the address on, with a code from the company and town", ctx do
      found(ctx, %{company: "Herbert Roofing"}, %{street: "12 Main St"})
      assert 1 == Postcards.add_cards(ctx.project, Postcards.candidates(ctx.project.id))

      [card] = Postcards.list_postcards(ctx.project.id)
      assert card.code == "herbert-roofing-grand-rapids"
      assert card.street == "12 Main St"
      assert Postcards.Postcard.city_line(card) == "Grand Rapids, MI 49503"
      assert card.trade == "roofing"
    end

    test "can't be removed once mailed", ctx do
      found(ctx)
      Postcards.add_cards(ctx.project, Postcards.candidates(ctx.project.id))
      [card] = Postcards.list_postcards(ctx.project.id)

      assert 1 == Postcards.mark_mailed(ctx.project.id, [card.id])
      assert {:error, :mailed} = Postcards.delete_postcard(Repo.reload(card))
    end
  end

  describe "a scan" do
    setup ctx do
      found(ctx, %{company: "Herbert Roofing"})
      Postcards.add_cards(ctx.project, Postcards.candidates(ctx.project.id))
      [card] = Postcards.list_postcards(ctx.project.id)
      %{card: card}
    end

    test "is counted and lands on the flyer's page, tagged as mail", %{card: card} do
      assert {:ok, scanned} = Postcards.record_scan(card.code, "iPhone")
      assert Repo.reload(card).scans_count == 1

      assert Postcards.destination_url(scanned) ==
               "https://exteriorpro.io/pro?s=#{card.code}&t=roofing&via=mail"
    end

    test "of an unknown code is an error" do
      assert :error = Postcards.record_scan("nope")
    end
  end

  test "the mailing list quotes what needs quoting", ctx do
    found(ctx, %{company: "Smith, Jones & Co"}, %{street: "5 Elm St"})
    Postcards.add_cards(ctx.project, Postcards.candidates(ctx.project.id))

    [header, row] =
      ctx.project.id
      |> Postcards.list_postcards()
      |> Postcards.to_csv()
      |> String.split("\r\n", trim: true)

    assert header == "Organization,Address,City,State,Zip,Code,QR URL"

    assert row =~
             ~s("Smith, Jones & Co",5 Elm St,Grand Rapids,MI,49503,smith-jones-co-grand-rapids,)

    assert row =~ "/m/smith-jones-co-grand-rapids"
  end

  test "the note fills in the company and falls back to a default" do
    assert [_lead | _] = Content.postcard_paragraphs(%Content{}, "Herbert Roofing")

    assert Content.postcard_paragraphs(
             %Content{postcard_note: "Hi {{company}}\n\nMore"},
             "Herbert Roofing"
           ) ==
             ["Hi Herbert Roofing", "More"]
  end
end
