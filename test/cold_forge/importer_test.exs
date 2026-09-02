defmodule ColdForge.ImporterTest do
  @moduledoc """
  The importer's job is to be predictable about a messy file. Every case here
  is something a bought list actually contains.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Importer

  setup do
    project = project_fixture()

    mapping = fn headers ->
      headers |> Importer.guess_mapping() |> Map.put(:__headers__, headers)
    end

    %{project: project, mapping: mapping}
  end

  describe "guess_mapping/1" do
    test "matches the same field however it's spelled" do
      assert %{email: 0} = Importer.guess_mapping(["Email Address"])
      assert %{email: 0} = Importer.guess_mapping(["e-mail"])
      assert %{email: 0} = Importer.guess_mapping(["EMAIL"])
      assert %{first_name: 0} = Importer.guess_mapping(["Given Name"])
      assert %{company: 0} = Importer.guess_mapping(["Organisation"])
      assert %{title: 0} = Importer.guess_mapping(["Job Title"])
    end

    test "leaves a column it doesn't recognise unmapped" do
      refute Map.has_key?(Importer.guess_mapping(["Roof Type"]), :email)
    end
  end

  describe "analyze/3" do
    test "classifies every row without writing anything", ctx do
      prospect_fixture(ctx.project, email: "already@example.com")
      Outreach.suppress("blocked@example.com", "unsubscribed")

      csv = """
      Email,First Name
      fresh@example.com,Fresh
      already@example.com,Already
      blocked@example.com,Blocked
      not-an-email,Broken
      ,Nameless
      """

      before = length(Outreach.list_prospects(ctx.project.id))

      {:ok, analysis} =
        Importer.analyze(csv, ctx.project.id, ctx.mapping.(["Email", "First Name"]))

      assert analysis.counts == %{new: 1, duplicate: 1, suppressed: 1, invalid: 2}
      assert length(Outreach.list_prospects(ctx.project.id)) == before
    end

    test "a repeated address inside the file counts as a duplicate", ctx do
      csv = """
      Email
      twice@example.com
      twice@example.com
      """

      {:ok, analysis} = Importer.analyze(csv, ctx.project.id, ctx.mapping.(["Email"]))

      assert analysis.counts == %{new: 1, duplicate: 1}
    end

    test "matches an existing prospect regardless of case", ctx do
      prospect_fixture(ctx.project, email: "mixed@example.com")

      csv = "Email\nMIXED@Example.com\n"
      {:ok, analysis} = Importer.analyze(csv, ctx.project.id, ctx.mapping.(["Email"]))

      assert analysis.counts == %{duplicate: 1}
    end

    test "handles quoted fields containing commas", ctx do
      csv = """
      Email,Company
      sam@example.com,"Rivera Roofing, LLC"
      """

      {:ok, analysis} = Importer.analyze(csv, ctx.project.id, ctx.mapping.(["Email", "Company"]))

      assert [%{status: :new, attrs: attrs}] = analysis.rows
      assert attrs[:company] == "Rivera Roofing, LLC"
    end

    test "reports a malformed file rather than raising", ctx do
      assert {:error, _} = Importer.analyze(~s|Email\n"unclosed|, ctx.project.id, %{email: 0})
    end
  end

  describe "commit/3" do
    test "inserts only the new rows", ctx do
      prospect_fixture(ctx.project, email: "already@example.com")
      Outreach.suppress("blocked@example.com", "bounced")

      csv = """
      Email,First Name,Company
      fresh@example.com,Fresh,Fresh Co
      already@example.com,Already,Already Co
      blocked@example.com,Blocked,Blocked Co
      """

      {:ok, result} =
        Importer.commit(csv, ctx.project.id, ctx.mapping.(["Email", "First Name", "Company"]))

      assert result.inserted == 1
      assert result.failed == []

      emails = Outreach.list_prospects(ctx.project.id) |> Enum.map(& &1.email) |> Enum.sort()
      assert emails == ["already@example.com", "fresh@example.com"]
    end

    test "keeps unmapped columns as merge-tag data", ctx do
      csv = """
      Email,Roof Type,Crew Size
      sam@example.com,Asphalt Shingle,4
      """

      headers = ["Email", "Roof Type", "Crew Size"]
      {:ok, _} = Importer.commit(csv, ctx.project.id, ctx.mapping.(headers))

      [prospect] = Outreach.list_prospects(ctx.project.id)
      assert prospect.custom_fields == %{"roof_type" => "Asphalt Shingle", "crew_size" => "4"}
    end

    test "an imported custom field is reachable from a merge tag", ctx do
      csv = "Email,Roof Type\nsam@example.com,Metal\n"
      {:ok, _} = Importer.commit(csv, ctx.project.id, ctx.mapping.(["Email", "Roof Type"]))

      [prospect] = Outreach.list_prospects(ctx.project.id)

      rendered =
        ColdForge.Sending.Renderer.preview(
          "You run a {{roof_type}} crew",
          prospect,
          ctx.project
        )

      assert rendered == "You run a Metal crew"
    end

    test "gives every imported prospect its own unsubscribe token", ctx do
      csv = "Email\na@example.com\nb@example.com\n"
      {:ok, _} = Importer.commit(csv, ctx.project.id, ctx.mapping.(["Email"]))

      tokens = Outreach.list_prospects(ctx.project.id) |> Enum.map(& &1.unsubscribe_token)

      assert length(tokens) == 2
      assert Enum.all?(tokens, &is_binary/1)
      assert length(Enum.uniq(tokens)) == 2
    end
  end
end
