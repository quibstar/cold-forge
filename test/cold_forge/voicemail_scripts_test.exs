defmodule ColdForge.VoicemailScriptsTest do
  @moduledoc """
  The four numbered voicemails: the defaults, what a project writes over them,
  and the rules the wording has to keep.

  The last group is the unusual one. Those assertions are about sales copy
  rather than code, and they are here because the constraints they encode came
  out of the pain-point research and are the kind of thing that erodes a line
  at a time — somebody tightens a sentence, and a script that asked a question
  starts making a claim nobody can stand behind.
  """
  use ColdForge.DataCase, async: true

  import ColdForge.OutreachFixtures

  alias ColdForge.Calling.Scripts
  alias ColdForge.Outreach

  setup do
    project = project_fixture(phone: "(616) 555-0142")

    prospect =
      prospect_fixture(project,
        first_name: "Dave",
        company: "Moore & Sons Roofing",
        industry: "roofing",
        custom_fields: %{"city" => "Grand Rapids"}
      )

    %{project: project, prospect: prospect}
  end

  describe "defaults" do
    test "there are four, each with a note saying when to use it" do
      assert length(Scripts.catalogue()) == 4
      assert Scripts.numbers() == [1, 2, 3, 4]

      for {number, note} <- Scripts.catalogue() do
        assert Scripts.default(number), "voicemail #{number} has no default"
        assert note =~ ~r/\w/
        assert Scripts.note(number) == note
      end
    end

    test "a default renders with this prospect's details in it", ctx do
      rendered = Scripts.render(1, ctx.prospect, ctx.project)

      assert rendered =~ "Dave"
      assert rendered =~ "Moore & Sons Roofing"
      assert rendered =~ "roofing"
      assert rendered =~ "(616) 555-0142"
    end

    test "a thin prospect still gets a sentence, not a gap", %{project: project} do
      nameless = prospect_fixture(project, first_name: nil, last_name: nil, company: nil)

      rendered = Scripts.render(1, nameless, project)

      assert rendered =~ "there"
      refute rendered =~ "{{"
    end

    test "no callback number means no script at all", ctx do
      {:ok, numberless} = Outreach.update_project(ctx.project, %{"phone" => ""})

      # A voicemail that says "ring me back on —" is a wasted call, and a
      # placeholder would be worse than an obvious gap.
      assert Scripts.render(1, ctx.prospect, numberless) == nil
    end
  end

  describe "a project writing over them" do
    test "its own wording wins", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          "voicemail_scripts" => %{"2" => "Hi {{company}}, it's Kris on {{callback}}."}
        })

      assert Scripts.render(2, ctx.prospect, project) ==
               "Hi Moore & Sons Roofing, it's Kris on (616) 555-0142."

      assert Scripts.rewritten?(2, project)
      # The ones it left alone keep the default.
      refute Scripts.rewritten?(1, project)
      assert Scripts.render(1, ctx.prospect, project) =~ "Had a quick idea"
    end

    test "a blank box keeps the default rather than sending nothing", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{"voicemail_scripts" => %{"2" => "   "}})

      assert project.voicemail_scripts == %{}

      assert Scripts.render(2, ctx.prospect, project) ==
               Scripts.default(2) |> then(&render(&1, ctx))
    end

    test "only the four numbers can be written", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          "voicemail_scripts" => %{"2" => "Kept.", "9" => "Nope.", "notes" => "Nope."}
        })

      assert project.voicemail_scripts == %{"2" => "Kept."}
    end

    test "a project that has never been edited stores nothing", ctx do
      assert ctx.project.voicemail_scripts == %{}
      assert Scripts.render(3, ctx.prospect, ctx.project) =~ "storm work"
    end
  end

  describe "voicemail 2, which the pain-point research rewrote" do
    setup ctx do
      Map.put(ctx, :text, Scripts.default(2))
    end

    test "it asks a question rather than asserting what everyone does", ctx do
      assert ctx.text =~ "?"

      # "Rewrite it so it doesn't assert prevalence at all — just ask, don't
      # claim." 70 pain points is a sample, not a population.
      for claim <- ["every contractor", "most shops", "everyone I talk to", "a lot of shops"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "it claims no customer it cannot name", ctx do
      # The wording it replaced said "I've helped a few West Michigan exterior
      # guys", and there is no nameable reference customer yet.
      for claim <- ["i've helped", "i have helped", "my customers", "clients of mine"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "it promises nothing about reliability, which is the thing it asks about", ctx do
      # All ten reliability points are marked unknown for ExteriorPro: there is
      # no uptime record to point at, so the script may ask and not answer.
      for claim <- ["never crashes", "always works", "rock solid", "more reliable", "offline"] do
        refute String.contains?(String.downcase(ctx.text), claim)
      end
    end

    test "it quotes no price, because there is no price sheet", ctx do
      refute Regex.match?(~r/\$\d/, ctx.text)
      refute String.contains?(String.downcase(ctx.text), "flat rate")
    end

    test "it keeps the rules every voicemail here keeps", ctx do
      rendered = Scripts.render(2, ctx.prospect, ctx.project)

      # The number twice — once to catch it, once to write it down.
      assert rendered |> String.split("(616) 555-0142") |> length() == 3

      # Under twenty seconds. Roughly 2.5 words a second read aloud, so the
      # ceiling is about 50; this leaves room without being a rule nobody can
      # meet.
      assert rendered |> String.split(~r/\s+/, trim: true) |> length() <= 70
    end
  end

  defp render(text, ctx), do: ColdForge.Sending.Renderer.preview(text, ctx.prospect, ctx.project)
end
