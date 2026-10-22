defmodule ColdForge.CallScriptsTest do
  @moduledoc """
  Scripts and voicemails as rows: adding, ordering, throwing out, and reading
  one with a prospect's details in it.

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
      voicemail = script(ctx.project, kind: "voicemail", name: "First attempt")

      assert first.position == 1
      assert second.position == 2
      # Its own list: a voicemail doesn't start at three because two scripts
      # already exist.
      assert voicemail.position == 1
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

    test "only the two kinds", ctx do
      assert {:error, changeset} =
               Outreach.create_call_script(%{
                 project_id: ctx.project.id,
                 kind: "postcard",
                 name: "No",
                 body: "No."
               })

      assert errors_on(changeset).kind != []
    end
  end

  describe "the lists" do
    test "come back in position order, each kind on its own", ctx do
      script(ctx.project, name: "Second", position: 2)
      script(ctx.project, name: "First", position: 1)
      script(ctx.project, kind: "voicemail", name: "Breakup", position: 4)

      assert Enum.map(Outreach.list_call_scripts(ctx.project.id, "script"), & &1.name) ==
               ["First", "Second"]

      assert Enum.map(Outreach.list_call_scripts(ctx.project.id, "voicemail"), & &1.name) ==
               ["Breakup"]
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

  describe "the voicemail cadence" do
    setup ctx do
      for default <- Scripts.defaults() do
        default
        |> Map.merge(%{project_id: ctx.project.id, kind: "voicemail"})
        |> Outreach.create_call_script()
      end

      ctx
    end

    test "renders the one at a position", ctx do
      assert Scripts.render(2, ctx.prospect, ctx.project) =~
               "what does the software you're on now"
    end

    test "a position nobody wrote is nothing", ctx do
      assert Scripts.render(9, ctx.prospect, ctx.project) == nil
    end

    test "no callback number means no voicemail at all", ctx do
      {:ok, numberless} = Outreach.update_project(ctx.project, %{"phone" => ""})

      # A voicemail that says "ring me back on —" is a wasted call, and a
      # placeholder would be worse than an obvious gap.
      assert Scripts.render(1, ctx.prospect, numberless) == nil
    end

    test "the name is what the screen calls it", ctx do
      assert Scripts.note(4, ctx.project) =~ "breakup"
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

  describe "voicemail 2, which the pain-point research wrote" do
    setup do
      %{text: Enum.find(Scripts.defaults(), &(&1.position == 2)).body}
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
    test "each has a name and a body, and they are numbered 1 to 4" do
      assert Enum.map(Scripts.defaults(), & &1.position) == [1, 2, 3, 4]

      for default <- Scripts.defaults() do
        assert default.name =~ ~r/\w/
        assert default.body =~ ~r/\w/
      end
    end

    test "each says the callback number twice — once to catch, once to write down" do
      for default <- Scripts.defaults() do
        count = default.body |> String.split("{{callback}}") |> length()
        assert count == 3, "voicemail #{default.position} says the number #{count - 1} time(s)"
      end
    end

    test "each is under twenty seconds read aloud" do
      for default <- Scripts.defaults() do
        words = default.body |> String.split(~r/\s+/, trim: true) |> length()
        assert words <= 70, "voicemail #{default.position} runs to #{words} words"
      end
    end
  end
end
