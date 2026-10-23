defmodule ColdForge.CallScriptsTest do
  @moduledoc """
  Scripts as rows: adding, ordering, throwing out, and reading one with a
  prospect's details in it.

  The wording group at the end is unusual — those assertions are about sales
  copy rather than code. They are here because the constraints came out of the
  pain-point research and are the kind that erode a line at a time: somebody
  tightens a sentence, and a script that asked a question starts making a claim
  nobody can stand behind.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Calling.Scripts
  alias ColdForge.Outreach
  alias ColdForge.Outreach.{CallScript, CallScripts}

  setup do
    project = project_fixture(phone: "(616) 555-0142")

    prospect =
      prospect_fixture(project,
        company: "Moore & Sons Roofing",
        industry: "roofing",
        custom_fields: %{"city" => "Grand Rapids"}
      )

    %{project: project, prospect: prospect}
  end

  defp script(project, attrs) do
    {:ok, script} =
      attrs
      |> Enum.into(%{project_id: project.id, kind: "script", name: "Script 1", body: "Hi."})
      |> Outreach.create_call_script()

    script
  end

  describe "adding one" do
    test "lands at the end of its own list", ctx do
      first = script(ctx.project, name: "Script 1")
      second = script(ctx.project, name: "Script 2")

      assert first.position == 1
      assert second.position == 2
    end

    test "a position can be given instead", ctx do
      assert script(ctx.project, position: 7).position == 7
    end

    test "two can't share a number", ctx do
      script(ctx.project, position: 1)

      assert {:error, changeset} =
               Outreach.create_call_script(%{
                 project_id: ctx.project.id,
                 kind: "script",
                 name: "Clash",
                 body: "Hi.",
                 position: 1
               })

      assert "is already taken by another one — two can't share a number" in errors_on(changeset).position
    end

    test "name and body are required, blank is not a script", ctx do
      assert {:error, changeset} =
               Outreach.create_call_script(%{project_id: ctx.project.id, kind: "script"})

      assert %{name: _, body: _} = errors_on(changeset)
    end

    test "voicemail is no longer a kind of its own", ctx do
      assert {:error, changeset} =
               Outreach.create_call_script(%{
                 project_id: ctx.project.id,
                 kind: "voicemail",
                 name: "No",
                 body: "No."
               })

      assert errors_on(changeset).kind != []
    end
  end

  describe "the lists" do
    test "come back in position order", ctx do
      script(ctx.project, name: "Second", position: 2)
      script(ctx.project, name: "First", position: 1)

      assert Enum.map(Outreach.list_call_scripts(ctx.project.id), & &1.name) ==
               ["First", "Second"]
    end

    test "one project's scripts are not another's", ctx do
      script(ctx.project, name: "Mine")
      other = project_fixture()

      assert Outreach.list_call_scripts(other.id, "script") == []
    end

    test "deleting takes it out of the list", ctx do
      one = script(ctx.project, name: "Going")
      {:ok, _} = Outreach.delete_call_script(one)

      assert Outreach.list_call_scripts(ctx.project.id, "script") == []
    end
  end

  describe "reading one for a prospect" do
    test "the prospect's details are read into the template", ctx do
      one = script(ctx.project, body: "Hi — is this {{company}}? Thirty seconds.")

      assert CallScripts.render(one, ctx.prospect, ctx.project) ==
               "Hi — is this Moore & Sons Roofing? Thirty seconds."
    end

    test "a tag with no value falls back rather than leaving a gap", ctx do
      thin = prospect_fixture(ctx.project, company: nil, industry: nil, phone: "(616) 555-0100")
      one = script(ctx.project, body: "[{{industry|exterior}} · {{city|West Michigan}}]")

      assert CallScripts.render(one, thin, ctx.project) == "[exterior · West Michigan]"
    end

    test "a multi-line script with colons in it survives", ctx do
      body = "THE GOAL\n\nYOU: Is the owner in?\n   ↳ STOP. Let them answer."
      one = script(ctx.project, body: body)

      assert CallScripts.render(one, ctx.prospect, ctx.project) == body
    end

    test "every prospect reads the same row, with no copy of its own", ctx do
      script(ctx.project, body: "Hi — is this {{company}}?")
      other = prospect_fixture(ctx.project, company: "Ace Roofing")

      [{_script, mine}] = CallScripts.for_prospect(ctx.prospect, ctx.project)
      [{_script, theirs}] = CallScripts.for_prospect(other, ctx.project)

      assert mine == "Hi — is this Moore & Sons Roofing?"
      assert theirs == "Hi — is this Ace Roofing?"
      assert other.custom_fields == %{}
    end

    test "the page opens on the first", ctx do
      first = script(ctx.project, name: "Script 1", position: 1)
      script(ctx.project, name: "Script 2", position: 2)

      assert ctx.prospect
             |> CallScripts.for_prospect(ctx.project)
             |> CallScripts.default_tab() == first.id
    end

    test "a project with nothing written has no tabs", ctx do
      assert CallScripts.for_prospect(ctx.prospect, ctx.project) == []
      assert CallScripts.default_tab([]) == nil
      refute CallScripts.any?(ctx.project)
    end
  end

  describe "the starter voicemails" do
    test "are one script, read like any other", ctx do
      {:ok, voicemails} =
        Scripts.voicemails()
        |> Map.put(:project_id, ctx.project.id)
        |> Outreach.create_call_script()

      assert voicemails.name == "Voicemails"
      assert [{_, rendered}] = CallScripts.for_prospect(ctx.prospect, ctx.project)
      assert rendered =~ "it's Kris, (616) 555-0142"
      assert rendered =~ "Had a quick idea for\nMoore & Sons Roofing"
    end
  end

  describe "tags without a fallback" do
    test "are reported, because they render as a hole mid-sentence", ctx do
      one =
        script(ctx.project, body: "A {{industry}} shop in {{city|West Michigan}}, {{company}}.")

      assert CallScript.tags_without_fallback(one) == ["industry", "company"]
    end

    test "a script that gives every tag one has nothing to report", ctx do
      one = script(ctx.project, body: "A {{industry|exterior}} shop in {{city|West Michigan}}.")

      assert CallScript.tags_without_fallback(one) == []
    end
  end

  # The starter script's four messages, without their headings.
  defp voicemails do
    Scripts.voicemails().body
    |> String.split(~r/^VOICEMAIL \d+ — .*$/m, trim: true)
    |> Enum.map(&String.trim/1)
  end

  describe "voicemail 2, which the pain-point research wrote" do
    setup do
      %{text: Enum.at(voicemails(), 1)}
    end

    test "asks a question rather than asserting what everyone does", ctx do
      assert ctx.text =~ "?"

      # 70 pain points is a sample, not a population.
      for claim <- ["every contractor", "most shops", "everyone i talk to", "a lot of shops"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "claims no customer it cannot name", ctx do
      # The wording it replaced said "I've helped a few West Michigan exterior
      # guys", and there is no nameable reference customer yet.
      for claim <- ["i've helped", "i have helped", "my customers", "clients of mine"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "promises nothing about the reliability it asks about", ctx do
      # All ten reliability points are marked unknown for ExteriorPro: there is
      # no uptime record to point at, so it may ask and not answer.
      for claim <- ["never crashes", "always works", "rock solid", "more reliable", "offline"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "quotes no price, because there is no price sheet", ctx do
      refute Regex.match?(~r/\$\d/, ctx.text)
      refute String.contains?(String.downcase(ctx.text), "flat rate")
    end
  end

  describe "the four built-in voicemails" do
    test "are headed and numbered 1 to 4" do
      assert Regex.scan(~r/^VOICEMAIL (\d+) — \S/m, Scripts.voicemails().body,
               capture: :all_but_first
             ) == [["1"], ["2"], ["3"], ["4"]]

      assert length(voicemails()) == 4
    end

    test "each says the callback number twice — once to catch, once to write down" do
      for {text, n} <- Enum.with_index(voicemails(), 1) do
        count = text |> String.split("{{callback}}") |> length()
        assert count == 3, "voicemail #{n} says the number #{count - 1} time(s)"
      end
    end

    test "each is under twenty seconds read aloud" do
      for {text, n} <- Enum.with_index(voicemails(), 1) do
        words = text |> String.split(~r/\s+/, trim: true) |> length()
        assert words <= 70, "voicemail #{n} runs to #{words} words"
      end
    end
  end
end
