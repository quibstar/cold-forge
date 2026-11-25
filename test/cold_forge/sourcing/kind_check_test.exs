defmodule ColdForge.Sourcing.KindCheckTest do
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.{Repo, Sourcing}
  alias ColdForge.Sourcing.{KindCheck, Org}

  # Shaped like the real pages: a groomer and daycare from the dog breeder
  # drips, and a breeder who also offers training and boarding.
  @groomer """
  <title>Otto's Pretty Paws | Grooming, Boarding and Daycare</title>
  <h1>Dog grooming in Oldsmar</h1><p>Full grooming, bath and brush, nail trims.
  Overnight boarding and doggy daycare. Book grooming online. Boarding rates.</p>
  """

  @breeder """
  <title>CapeWest Retrievers</title><p>AKC Labrador puppies from champion lines.
  Our next litter is due in March; a deposit holds your place on the waitlist.
  We also offer obedience training and boarding for our puppy families.</p>
  """

  describe "check/2" do
    test "holds a breeder result whose site reads like grooming and boarding" do
      assert {:hold, note} = KindCheck.check("breeder", [@groomer])
      assert note == "Website reads like grooming and boarding, not breeding"
    end

    test "keeps a breeder who also trains and boards" do
      assert KindCheck.check("breeder", [@breeder]) == :ok
    end

    test "judges every page the crawl read, homepage included" do
      contact = "<p>Call us or email info@example.com</p>"
      assert {:hold, _} = KindCheck.check("dog breeder", [contact, @groomer])
    end

    test "never holds other searches" do
      assert KindCheck.check("shelter", [@groomer]) == :ok
      assert KindCheck.check("roofing", [@groomer]) == :ok
      assert KindCheck.check(nil, [@groomer]) == :ok
    end

    test "a site with little to go on is not held" do
      assert KindCheck.check("breeder", ["<p>Grooming available.</p>"]) == :ok
      assert KindCheck.check("breeder", []) == :ok
    end
  end

  describe "a held place" do
    setup do
      project = project_fixture()

      {:ok, source} =
        Sourcing.create_source(%{
          name: "Dog breeders #{System.unique_integer([:positive])}",
          project_id: project.id,
          provider: "places",
          segments: ["breeder"],
          localities: ["Tampa, FL"]
        })

      org = fn name ->
        %Org{}
        |> Org.discovery_changeset(%{
          name: name,
          segment: "breeder",
          provider: "places",
          source_ref: "ref-#{System.unique_integer([:positive])}",
          website: "https://example.test",
          phone: "(813) 555-0101"
        })
        |> Ecto.Changeset.put_change(:source_id, source.id)
        |> Repo.insert!()
      end

      candidate = %{
        email: "info@example.test",
        source_url: "https://example.test",
        presentation: :mailto
      }

      {:ok, groomer} =
        Sourcing.record_found(org.("Otto's Pretty Paws"), candidate, %{has_contact_form: false},
          pages: [@groomer]
        )

      {:ok, breeder} =
        Sourcing.record_found(org.("CapeWest Retrievers"), candidate, %{has_contact_form: false},
          pages: [@breeder]
        )

      %{source: source, groomer: groomer, breeder: breeder}
    end

    test "is in Check first, not Email, with the reason", ctx do
      assert ctx.groomer.review_note =~ "grooming"
      assert Sourcing.view_of(ctx.groomer) == "review"
      assert Sourcing.view_of(ctx.breeder) == "email"

      counts = Sourcing.counts_by_view(ctx.source)
      assert counts["review"] == 1
      assert counts["email"] == 1
    end

    test "Add all leaves it out", ctx do
      assert {:ok, _totals} = Sourcing.promote_all(ctx.source, :email)

      assert Repo.get!(Org, ctx.breeder.id).status == "promoted"
      assert Repo.get!(Org, ctx.groomer.id).status == "fetched"
    end

    test "Looks right moves it back to Email", ctx do
      assert {:ok, org} = Sourcing.clear_review(ctx.groomer)
      assert org.review_note == nil
      assert Sourcing.view_of(org) == "email"
    end
  end
end
