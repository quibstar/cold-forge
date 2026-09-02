defmodule ColdForge.MergeValuesTest do
  @moduledoc """
  Where a merge tag's value comes from.

  Four levels resolve into one value, and getting the order wrong is invisible
  until an email tells four hundred roofers they run a siding company.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Sending.Renderer

  defp render(body, prospect, project, campaign \\ nil) do
    Renderer.preview(body, prospect, project, campaign)
  end

  describe "resolution order, most specific first" do
    test "the prospect's own field beats everything" do
      project = project_fixture(merge_defaults: %{"industry" => "contractors"})

      {:ok, campaign} =
        Outreach.create_campaign(%{
          "project_id" => project.id,
          "name" => "c",
          "merge_defaults_text" => "industry: roofing"
        })

      prospect = prospect_fixture(project, industry: "gutters")

      assert render("{{industry|nothing}}", prospect, project, campaign) == "gutters"
    end

    test "their extra fields beat the campaign" do
      project = project_fixture(merge_defaults: %{"trade" => "contractors"})

      {:ok, campaign} =
        Outreach.create_campaign(%{
          "project_id" => project.id,
          "name" => "c",
          "merge_defaults_text" => "trade: roofing"
        })

      prospect = prospect_fixture(project, custom_fields: %{"trade" => "gutters"})

      assert render("{{trade}}", prospect, project, campaign) == "gutters"
    end

    test "the campaign beats the project" do
      project = project_fixture(merge_defaults: %{"industry" => "contractors"})

      {:ok, campaign} =
        Outreach.create_campaign(%{
          "project_id" => project.id,
          "name" => "c",
          "merge_defaults_text" => "industry: roofing"
        })

      prospect = prospect_fixture(project)

      assert render("{{industry}}", prospect, project, campaign) == "roofing"
    end

    test "the project stands in when nothing else has it" do
      project = project_fixture(merge_defaults: %{"industry" => "contractors"})
      {:ok, campaign} = Outreach.create_campaign(%{"project_id" => project.id, "name" => "c"})
      prospect = prospect_fixture(project)

      assert render("{{industry}}", prospect, project, campaign) == "contractors"
    end

    test "the pipe fallback is the last resort" do
      project = project_fixture()
      prospect = prospect_fixture(project)

      assert render("{{industry|contractors}}", prospect, project) == "contractors"
    end
  end

  describe "blanks do not shadow" do
    test "an empty prospect field falls through to the campaign" do
      project = project_fixture()

      {:ok, campaign} =
        Outreach.create_campaign(%{
          "project_id" => project.id,
          "name" => "c",
          "merge_defaults_text" => "industry: roofing"
        })

      # Blank rather than nil — an importer writing "" must behave like absent,
      # or a stray empty column silently blanks the tag for the whole campaign.
      prospect = prospect_fixture(project, industry: "   ")

      assert render("{{industry|nothing}}", prospect, project, campaign) == "roofing"
    end
  end

  describe "the editor" do
    test "parses one name: value per line, slugging the name" do
      assert ColdForge.MergeFields.from_text("Crew Size: 6\n\nindustry: roofing\njunk line") ==
               %{"crew_size" => "6", "industry" => "roofing"}
    end

    test "round-trips through the textarea" do
      fields = %{"crew_size" => "6", "industry" => "roofing"}

      assert fields |> ColdForge.MergeFields.to_text() |> ColdForge.MergeFields.from_text() ==
               fields
    end

    test "a campaign default set through the form reaches an email" do
      project = project_fixture()

      {:ok, campaign} =
        Outreach.create_campaign(%{
          "project_id" => project.id,
          "name" => "c",
          "merge_defaults_text" => "industry: roofing\ncrew_size: 6"
        })

      assert campaign.merge_defaults == %{"industry" => "roofing", "crew_size" => "6"}

      prospect = prospect_fixture(project)

      assert render("a {{industry}} crew of {{crew_size}}", prospect, project, campaign) ==
               "a roofing crew of 6"
    end
  end
end
