defmodule ColdForge.ExteriorproImportTest do
  @moduledoc """
  What each ExteriorPro column becomes, and what a second run does.

  The mapping is tested apart from the Mix task that drives it, because the
  task's job is two database connections and the mapping's job is the judgment
  — which status means what, where a page of script goes, what a re-import is
  allowed to overwrite. Only the second of those is worth pinning down.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach.{ExteriorproImport, Prospect}

  # A row shaped the way the real list is: a phone number, a city, a fit grade,
  # four hand-written scripts, and nothing else.
  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "01a03eac-29a6-75f6-8748-16a1056d5c87",
        "company" => "Moore & Sons Roofing",
        "contact_name" => nil,
        "contact_role" => nil,
        "phone" => "(616) 779-5824",
        "email" => nil,
        "website" => nil,
        "city" => "Grand Rapids",
        "state_province" => nil,
        "trades" => [],
        "employee_estimate" => nil,
        "current_software" => nil,
        "source" => "NEPQ call sheet",
        "fit" => "High",
        "status" => "new",
        "next_action_on" => nil,
        "notes" => nil,
        "last_contacted_at" => nil,
        "opener" => "Is the owner in?",
        "problem_question" => "How are you keeping track?",
        "objections" => "Too busy -> that's not a problem.",
        "voicemail" => "Hey, it's just Kris.",
        "script_direct" => nil,
        "script_nepq" => nil
      },
      overrides
    )
  end

  describe "the columns that keep their names" do
    test "company, phone and notes come straight across" do
      attrs = ExteriorproImport.to_attrs(row(%{"notes" => "Called, no answer."}), "p")

      assert attrs.company == "Moore & Sons Roofing"
      assert attrs.phone == "(616) 779-5824"
      assert attrs.notes == "Called, no answer."
      assert attrs.project_id == "p"
    end

    test "the phone column is kept verbatim, placeholder and all" do
      attrs = ExteriorproImport.to_attrs(row(%{"phone" => "— look up —"}), "p")

      # Nulling it would fail the email-or-phone check constraint and lose the
      # row entirely; `Prospect.dialable?/1` is what stops the interface
      # offering a dead `tel:` link.
      assert attrs.phone == "— look up —"
      refute Prospect.dialable?(%Prospect{phone: attrs.phone})
    end

    test "a blank is a nil, not an empty string" do
      attrs = ExteriorproImport.to_attrs(row(%{"company" => "  ", "notes" => ""}), "p")

      assert attrs.company == nil
      assert attrs.notes == nil
    end
  end

  describe "one contact name into two columns" do
    test "first word, then everything after it" do
      assert ExteriorproImport.split_name("Dave Moore") == {"Dave", "Moore"}
      assert ExteriorproImport.split_name("Mary Beth Van Dyke") == {"Mary", "Beth Van Dyke"}
    end

    test "one word is a first name" do
      assert ExteriorproImport.split_name("Dave") == {"Dave", nil}
    end

    test "nothing is nothing" do
      assert ExteriorproImport.split_name(nil) == {nil, nil}
      assert ExteriorproImport.split_name("   ") == {nil, nil}
    end
  end

  describe "status, which is not the same word in both apps" do
    test "everyone still worth ringing lands on new" do
      for status <- ~w(new callback contacted) do
        attrs = ExteriorproImport.to_attrs(row(%{"status" => status}), "p")

        assert attrs.status == "new", "#{status} should stay in the call queue"
        refute attrs.do_not_call
      end
    end

    test "won is out of the queue the way a conversation leaves it" do
      attrs = ExteriorproImport.to_attrs(row(%{"status" => "won"}), "p")

      assert attrs.status == "replied"
      refute attrs.do_not_call
    end

    test "lost stops the calls and the email both" do
      attrs = ExteriorproImport.to_attrs(row(%{"status" => "lost"}), "p")

      assert attrs.status == "unsubscribed"
      assert attrs.do_not_call
    end

    test "the original word is kept wherever the two differ" do
      assert ExteriorproImport.custom_fields(row(%{"status" => "callback"}))[
               "exteriorpro_status"
             ] == "callback"

      # `new` means the same thing in both, so recording it would be 112 rows
      # of noise in the field editor.
      refute Map.has_key?(ExteriorproImport.custom_fields(row()), "exteriorpro_status")
    end
  end

  describe "dates" do
    test "a callback date becomes a calling hour, not midnight" do
      attrs = ExteriorproImport.to_attrs(row(%{"next_action_on" => ~D[2026-11-03]}), "p")

      # Midnight UTC would make the row due at eight the evening before, in the
      # project's own timezone.
      assert attrs.next_call_at == ~U[2026-11-03 13:00:00Z]
    end

    test "last contacted becomes last called, and counts as one attempt" do
      attrs =
        ExteriorproImport.to_attrs(row(%{"last_contacted_at" => ~N[2026-10-19 14:30:00]}), "p")

      assert attrs.last_called_at == ~U[2026-10-19 14:30:00Z]
      assert attrs.call_attempts == 1
    end

    test "never contacted is no attempts" do
      assert ExteriorproImport.to_attrs(row(), "p").call_attempts == 0
    end
  end

  describe "trades" do
    test "the first one answers what kind of shop this is" do
      attrs = ExteriorproImport.to_attrs(row(%{"trades" => ["Roofing", "Siding"]}), "p")

      assert attrs.industry == "Roofing"
      assert attrs.custom_fields["trades"] == "Roofing, Siding"
    end

    test "an empty list is not an industry" do
      attrs = ExteriorproImport.to_attrs(row(), "p")

      assert attrs.industry == nil
      refute Map.has_key?(attrs.custom_fields, "trades")
    end
  end

  describe "provenance" do
    test "source says where the row came from, forever" do
      attrs = ExteriorproImport.to_attrs(row(), "p")

      assert attrs.source == "exteriorpro:prospecting"
      # Which sheet it came off is a different question from which app.
      assert attrs.custom_fields["source_list"] == "NEPQ call sheet"
      assert attrs.custom_fields["exteriorpro_id"] == "01a03eac-29a6-75f6-8748-16a1056d5c87"
    end

    test "city, state and fit keep their places" do
      fields =
        ExteriorproImport.custom_fields(
          row(%{"state_province" => "MI", "employee_estimate" => "6-10"})
        )

      assert fields["city"] == "Grand Rapids"
      assert fields["state"] == "MI"
      assert fields["fit"] == "High"
      assert fields["employee_estimate"] == "6-10"
    end

    test "phone_digits is the one column deliberately dropped" do
      attrs = ExteriorproImport.to_attrs(row(%{"phone_digits" => "6167795824"}), "p")

      refute Map.has_key?(attrs.custom_fields, "phone_digits")
    end
  end

  describe "classifying a row" do
    setup do
      %{project: project_fixture()}
    end

    test "a row with no match is new", ctx do
      assert {:new, attrs} = ExteriorproImport.classify(row(), ctx.project.id, nil)
      assert attrs.company == "Moore & Sons Roofing"
    end

    test "a row with no company name is not importable", ctx do
      assert {:invalid, reason} =
               ExteriorproImport.classify(row(%{"company" => nil}), ctx.project.id, nil)

      assert reason =~ "company"
    end

    test "a row with neither phone nor email is not importable", ctx do
      assert {:invalid, reason} =
               ExteriorproImport.classify(row(%{"phone" => nil}), ctx.project.id, nil)

      assert reason =~ "neither"
    end
  end

  describe "running it twice" do
    setup do
      project = project_fixture()

      existing =
        prospect_fixture(project,
          email: nil,
          phone: "(616) 779-5824",
          first_name: nil,
          last_name: nil,
          company: "Moore & Sons Roofing",
          notes: "Spoke to Dave, call back after the storm.",
          custom_fields: %{"exteriorpro_id" => row()["id"]}
        )

      %{project: project, existing: existing}
    end

    test "an unchanged row is left alone", ctx do
      # Everything this row carries is already here or already blank on both
      # sides, bar the scripts the existing row is missing.
      assert {:changed, _changes, fields} =
               ExteriorproImport.classify(row(), ctx.project.id, ctx.existing)

      # The city and the fit grade it is missing — not the scripts, which are
      # the project's now and never land on a prospect.
      assert "city" in fields
      refute "notes" in fields
      refute "opener" in fields
    end

    test "blanks are filled, typed values are not touched", ctx do
      changes =
        ExteriorproImport.changes(
          ctx.existing,
          ExteriorproImport.to_attrs(row(%{"notes" => "From the sheet."}), ctx.project.id)
        )

      # The note on the Cold Forge row was typed after a call. It wins.
      refute Map.has_key?(changes, :notes)
    end

    test "the working state a re-import must never reset", ctx do
      changes =
        ExteriorproImport.changes(
          ctx.existing,
          ExteriorproImport.to_attrs(row(%{"status" => "lost"}), ctx.project.id)
        )

      for field <- [
            :status,
            :next_call_at,
            :last_called_at,
            :call_attempts,
            :do_not_call,
            :source
          ] do
        refute Map.has_key?(changes, field),
               "#{field} is Cold Forge's own state once the row is here"
      end
    end

    test "nothing left to do reads as unchanged", ctx do
      {:ok, filled} =
        ColdForge.Outreach.update_prospect(ctx.existing, %{
          custom_fields:
            Map.merge(ctx.existing.custom_fields, ExteriorproImport.custom_fields(row()))
        })

      assert ExteriorproImport.classify(row(), ctx.project.id, filled) == :unchanged
    end
  end
end
