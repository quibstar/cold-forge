defmodule ColdForge.CallScriptsTest do
  @moduledoc """
  The per-business call scripts, and the save that must not lose them.

  The round-trip tests are the point of this file. The scripts are prose
  somebody hand-wrote and iterated on for months, they live in the same map as
  the short one-per-line extras, and a `name: value` line cannot hold a page of
  text — so the first thing to prove is that editing one half never drops the
  other.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Outreach.{CallScripts, Prospect}

  @opener """
  "Is the owner in? … Hey, this is just Kris."
     ↳ STOP. Let them answer.

  Note: this line has a colon in it, which a one-per-line editor would read as
  a field name.
  """

  setup do
    project = project_fixture()

    prospect =
      prospect_fixture(project,
        custom_fields: %{
          "opener" => @opener,
          "voicemail" => "Hey, it's just Kris.",
          "city" => "Grand Rapids",
          "fit" => "High"
        }
      )

    %{project: project, prospect: prospect}
  end

  describe "splitting the map" do
    test "scripts and extras come apart", ctx do
      assert CallScripts.scripts(ctx.prospect.custom_fields) == %{
               "opener" => @opener,
               "voicemail" => "Hey, it's just Kris."
             }

      assert CallScripts.extras(ctx.prospect.custom_fields) == %{
               "city" => "Grand Rapids",
               "fit" => "High"
             }
    end

    test "a nil map is not a crash", ctx do
      assert CallScripts.scripts(nil) == %{}
      assert CallScripts.extras(nil) == %{}
      assert CallScripts.available(%Prospect{custom_fields: nil}, ctx.project) == []
    end
  end

  describe "tabs" do
    test "only the ones there is a script for", ctx do
      assert CallScripts.available(ctx.prospect, ctx.project) == [{"original", "Script 1"}]
      assert CallScripts.default_tab(ctx.prospect, ctx.project) == "original"
      assert CallScripts.any?(ctx.prospect, ctx.project)
    end

    test "opens on whichever script there is, not on a blank tab", ctx do
      nepq_only = prospect_fixture(ctx.project, custom_fields: %{"script_nepq" => "Five stages."})

      assert CallScripts.available(nepq_only, ctx.project) == [{"nepq", "NEPQ Awareness"}]
      assert CallScripts.default_tab(nepq_only, ctx.project) == "nepq"
    end

    test "no scripts at all is not a tab", ctx do
      bare = prospect_fixture(ctx.project)

      refute CallScripts.any?(bare, ctx.project)
      assert CallScripts.available(bare, ctx.project) == []
    end

    test "parts come back in reading order, blanks dropped", ctx do
      assert CallScripts.parts(ctx.prospect, ctx.project, "original") == [{"Opener", @opener}]
      assert CallScripts.parts(ctx.prospect, ctx.project, "direct") == []
    end

    test "the voicemail is shown under every tab, not just its own", ctx do
      # Which script you opened with says nothing about whether anybody picks
      # up, so it cannot belong to one tab.
      assert CallScripts.always(ctx.prospect, ctx.project) ==
               [{"Voicemail", "Hey, it's just Kris."}]

      refute {"Voicemail", "Hey, it's just Kris."} in CallScripts.parts(
               ctx.prospect,
               ctx.project,
               "original"
             )
    end

    test "no voicemail written is nothing shown, not an empty heading", %{project: project} do
      bare = prospect_fixture(project, custom_fields: %{"opener" => "Just an opener."})

      assert CallScripts.always(bare, project) == []
    end
  end

  describe "the project's templates" do
    setup ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          "call_scripts" => %{
            "script_direct" => "Hi — is this {{company}}? Thirty seconds.",
            "script_nepq" => "A {{industry|exterior}} shop in {{city|West Michigan}}.",
            "opener" => "The template opener, which {{company}} should not see."
          }
        })

      Map.put(ctx, :project, project)
    end

    test "a template is read with this prospect's details in it", ctx do
      assert CallScripts.body(ctx.prospect, ctx.project, "script_direct") ==
               "Hi — is this Rivera Roofing? Thirty seconds."
    end

    test "a tag with no value falls back rather than leaving a gap", ctx do
      # No industry, and `city` is a custom field this prospect does have.
      assert CallScripts.body(ctx.prospect, ctx.project, "script_nepq") ==
               "A exterior shop in Grand Rapids."
    end

    test "the prospect's own wording wins over the template", ctx do
      assert CallScripts.body(ctx.prospect, ctx.project, "opener") == @opener
      assert CallScripts.overridden(ctx.prospect, ctx.project) == ["opener"]
    end

    test "a template gives every prospect the tab, with no copies stored", ctx do
      bare = prospect_fixture(ctx.project, company: "Ace Roofing")

      assert CallScripts.available(bare, ctx.project) == [
               {"original", "Script 1"},
               {"direct", "Script 2"},
               {"nepq", "NEPQ Awareness"}
             ]

      assert CallScripts.body(bare, ctx.project, "script_direct") ==
               "Hi — is this Ace Roofing? Thirty seconds."

      # Nothing of the script is on the prospect — that was the point.
      assert CallScripts.scripts(bare.custom_fields) == %{}
    end

    test "blank and unknown keys never become a template", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          "call_scripts" => %{"opener" => "  ", "nonsense" => "x", "voicemail" => " Hi. "}
        })

      assert project.call_scripts == %{"voicemail" => "Hi."}
    end
  end

  describe "saving the form" do
    test "editing the extras leaves the scripts alone", ctx do
      # What the prospect form sends when somebody changes a short field: the
      # one-per-line textarea, which never showed the scripts.
      {:ok, updated} =
        Outreach.update_prospect(ctx.prospect, %{
          "custom_fields_text" => "city: Kalamazoo\nfit: High"
        })

      assert updated.custom_fields["city"] == "Kalamazoo"
      assert updated.custom_fields["opener"] == @opener
      assert updated.custom_fields["voicemail"] == "Hey, it's just Kris."
    end

    test "editing a script leaves the extras alone", ctx do
      {:ok, updated} =
        Outreach.update_prospect(ctx.prospect, %{
          "custom_fields_text" => "city: Grand Rapids\nfit: High",
          "call_scripts" => %{"opener" => "A shorter opener.", "script_direct" => "Straight in."}
        })

      assert updated.custom_fields["opener"] == "A shorter opener."
      assert updated.custom_fields["script_direct"] == "Straight in."
      assert updated.custom_fields["city"] == "Grand Rapids"
      # Submitted blank, so it goes — blanking a textarea means delete.
      refute Map.has_key?(updated.custom_fields, "voicemail")
    end

    test "a multi-line script survives a save, colons and all", ctx do
      {:ok, once} =
        Outreach.update_prospect(ctx.prospect, %{"call_scripts" => %{"opener" => @opener}})

      # Twice, because the failure this guards against only shows on the second
      # pass: the first save renders the map into the editor, the second reads
      # it back.
      {:ok, twice} =
        Outreach.update_prospect(once, %{
          "call_scripts" => %{"opener" => once.custom_fields["opener"]}
        })

      # Trimmed on the way in — a textarea's trailing newline is not content —
      # and byte-identical from then on, which is the property that matters.
      assert twice.custom_fields["opener"] == String.trim(@opener)
      assert twice.custom_fields["opener"] == once.custom_fields["opener"]

      # The colon-bearing line stayed inside the script instead of becoming a
      # field of its own, which is what the one-per-line editor would do to it.
      assert twice.custom_fields |> Map.keys() |> Enum.sort() == ["city", "fit", "opener"]
    end

    test "whitespace-only is not a script", ctx do
      {:ok, updated} =
        Outreach.update_prospect(ctx.prospect, %{"call_scripts" => %{"opener" => "   \n  "}})

      refute Map.has_key?(updated.custom_fields, "opener")
    end

    test "a key that isn't a script can't be smuggled in through the script form", ctx do
      {:ok, updated} =
        Outreach.update_prospect(ctx.prospect, %{
          "custom_fields_text" => "city: Grand Rapids",
          "call_scripts" => %{"opener" => "Hi.", "secret" => "nope"}
        })

      refute Map.has_key?(updated.custom_fields, "secret")
    end

    test "attrs with atom keys pass straight through, as the importers send them", ctx do
      {:ok, updated} =
        Outreach.update_prospect(ctx.prospect, %{custom_fields: %{"roof_type" => "Asphalt"}})

      assert updated.custom_fields == %{"roof_type" => "Asphalt"}
    end
  end

  describe "merge tags" do
    test "a script is reachable from an email, which it wasn't in ExteriorPro", ctx do
      values = Map.new(Prospect.merge_values(ctx.prospect))

      assert values["opener"] == @opener
      assert values["fit"] == "High"
    end
  end
end
