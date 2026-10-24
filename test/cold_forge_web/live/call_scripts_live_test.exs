defmodule ColdForgeWeb.CallScriptsLiveTest do
  @moduledoc """
  The scripts screen and the call page that reads from it.

  This is the half of the ExteriorPro move that had to be built rather than
  copied: the scripts came across as data, but a call list you can't read a
  script off while the phone is ringing is a worse tool than the one it
  replaced.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.{Calling, Outreach}

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro", phone: "(616) 555-0142")

    {:ok, script} =
      Outreach.create_call_script(%{
        project_id: project.id,
        kind: "script",
        name: "Script 1",
        body: "Is the owner in? This is about {{company}} in {{city|West Michigan}}."
      })

    {:ok, nepq} =
      Outreach.create_call_script(%{
        project_id: project.id,
        kind: "script",
        name: "NEPQ Awareness",
        body: "The five stages, for a {{industry|exterior}} shop."
      })

    prospect =
      prospect_fixture(project,
        email: nil,
        phone: "(616) 779-5824",
        company: "Moore & Sons Roofing",
        first_name: nil,
        last_name: nil,
        industry: "roofing",
        custom_fields: %{"city" => "Grand Rapids", "fit" => "High"}
      )

    %{
      conn: log_in_user(conn, user_fixture()),
      project: project,
      prospect: prospect,
      script: script,
      nepq: nepq
    }
  end

  defp scripts_path(project), do: ~p"/admin/p/#{project.id}/scripts"
  defp queue_path(project), do: ~p"/admin/p/#{project.id}/calls"
  defp call_path(project, prospect), do: ~p"/admin/p/#{project.id}/calls/#{prospect.id}"

  describe "the scripts screen" do
    test "lists the scripts", ctx do
      {:ok, _view, html} = live(ctx.conn, scripts_path(ctx.project))

      assert html =~ "Script 1"
      assert html =~ "NEPQ Awareness"
    end

    test "the starter voicemails are added as one script, once", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view |> element("#add-voicemails") |> render_click()

      assert [%{name: "Voicemails", position: 3, body: body}] =
               ctx.project.id
               |> Outreach.list_call_scripts()
               |> Enum.filter(&(&1.name == "Voicemails"))

      assert body =~ "VOICEMAIL 4"
      refute has_element?(view, "#add-voicemails")
    end

    test "one can be added", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view |> element("button[phx-click='new']") |> render_click()

      view
      |> form("#script-form", call_script: %{"name" => "Script 2", "body" => "Straight pitch."})
      |> render_submit()

      names = ctx.project.id |> Outreach.list_call_scripts("script") |> Enum.map(& &1.name)
      assert "Script 2" in names
    end

    test "a new one lands at the end rather than colliding", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view |> element("button[phx-click='new']") |> render_click()

      view
      |> form("#script-form", call_script: %{"name" => "Third", "body" => "Hi."})
      |> render_submit()

      assert ctx.project.id
             |> Outreach.list_call_scripts("script")
             |> Enum.map(& &1.position) == [1, 2, 3]
    end

    test "one can be edited", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view
      |> element("button[phx-value-id='#{ctx.script.id}'][phx-click='edit']")
      |> render_click()

      view
      |> form("#script-form", call_script: %{"name" => "Script 1", "body" => "Reworded."})
      |> render_submit()

      assert Outreach.get_call_script!(ctx.script.id).body == "Reworded."
    end

    test "one can be thrown out", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view
      |> element("button[phx-value-id='#{ctx.nepq.id}'][phx-click='delete']")
      |> render_click()

      names = ctx.project.id |> Outreach.list_call_scripts("script") |> Enum.map(& &1.name)
      refute "NEPQ Awareness" in names
    end

    test "they can be reordered without two ever sharing a number", ctx do
      {:ok, view, _html} = live(ctx.conn, scripts_path(ctx.project))

      view
      |> element("button[phx-click='move'][phx-value-id='#{ctx.nepq.id}'][phx-value-by='-1']")
      |> render_click()

      assert ctx.project.id
             |> Outreach.list_call_scripts("script")
             |> Enum.map(&{&1.name, &1.position}) == [{"NEPQ Awareness", 1}, {"Script 1", 2}]
    end

    test "the placeholders are listed against a real prospect", ctx do
      {:ok, _view, html} = live(ctx.conn, scripts_path(ctx.project))

      assert html =~ "Placeholders"
      assert html =~ "Moore &amp; Sons Roofing"
      assert html =~ "Grand Rapids"
      assert html =~ "(616) 555-0142"
    end

    test "a tag that would render blank is flagged", ctx do
      # No first name on this prospect, and no fallback on the tag, so the
      # script reads "Hey , it's Kris" out loud.
      {:ok, _} = Outreach.update_call_script(ctx.script, %{"body" => "Hey {{first_name}}, Kris."})

      {:ok, _view, html} = live(ctx.conn, scripts_path(ctx.project))

      assert html =~ "renders blank"
      assert html =~ "{{first_name}}"
    end

    test "a tag without a fallback whose field is filled in is left alone", ctx do
      # `{{company}}` has no fallback either, but every row on this list has a
      # company — flagging it would put a badge on every script and teach
      # nobody anything.
      {:ok, _} = Outreach.update_call_script(ctx.script, %{"body" => "Is this {{company}}?"})

      {:ok, _view, html} = live(ctx.conn, scripts_path(ctx.project))

      refute html =~ "renders blank"
    end
  end

  describe "the call page" do
    test "shows the project's script with this prospect's details in it", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.prospect))

      assert html =~ "Is the owner in? This is about Moore &amp; Sons Roofing in Grand Rapids."
    end

    test "a tab per script, opening on the first", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.prospect))

      assert has_element?(view, "button[phx-value-tab='#{ctx.script.id}']")
      assert has_element?(view, "button[phx-value-tab='#{ctx.nepq.id}']")

      html = view |> element("button[phx-value-tab='#{ctx.nepq.id}']") |> render_click()
      assert html =~ "The five stages, for a roofing shop."
      refute html =~ "Is the owner in?"
    end

    test "voicemails are a tab like any other", ctx do
      {:ok, voicemails} =
        Outreach.create_call_script(%{
          project_id: ctx.project.id,
          name: "Voicemails",
          body: "Hey, it's Kris on {{callback}} about {{company}}."
        })

      {:ok, view, html} = live(ctx.conn, call_path(ctx.project, ctx.prospect))

      # Not under the script you opened with: only on its own tab.
      refute html =~ "Hey, it&#39;s Kris"

      html = view |> element("button[phx-value-tab='#{voicemails.id}']") |> render_click()
      assert html =~ "Hey, it&#39;s Kris on (616) 555-0142 about Moore &amp; Sons Roofing."
    end

    test "a project with nothing written says so and points at the screen", ctx do
      bare = project_fixture(name: "Bare", phone: "(616) 555-0000")
      lonely = prospect_fixture(bare, phone: "(616) 555-0001", email: nil)

      {:ok, _view, html} = live(ctx.conn, call_path(bare, lonely))

      assert html =~ "Nothing written yet."
      assert html =~ ~s|/admin/p/#{bare.id}/scripts|
    end
  end

  describe "the queue" do
    test "each row links to that prospect's own page", ctx do
      {:ok, view, _html} = live(ctx.conn, queue_path(ctx.project))

      assert view |> element("#queue-#{ctx.prospect.id}") |> render_click() ==
               {:error,
                {:live_redirect, %{kind: :push, to: call_path(ctx.project, ctx.prospect)}}}
    end

    test "best fit first among people nobody has rung", ctx do
      low =
        prospect_fixture(ctx.project, phone: "(616) 555-0111", custom_fields: %{"fit" => "Low"})

      medium =
        prospect_fixture(ctx.project,
          phone: "(616) 555-0122",
          custom_fields: %{"fit" => "Medium"}
        )

      ids = ctx.project.id |> Calling.queue() |> Enum.map(& &1.id)

      assert Enum.take(ids, 3) == [ctx.prospect.id, medium.id, low.id]
    end

    test "the badge counts everyone due, not the rows on the page", ctx do
      for n <- 1..60,
          do: prospect_fixture(ctx.project, phone: "(616) 555-02#{n}", email: nil)

      {:ok, view, html} = live(ctx.conn, queue_path(ctx.project))

      # 61 with the one from setup. Before this the badge read 50 whatever the
      # real number was, because it counted the list it had been handed.
      assert html =~ "61"
      assert html =~ "1–50 of 61"
      assert html =~ "Page 1 of 2"

      rows = fn -> view |> render() |> then(&Regex.scan(~r/id="queue-/, &1)) |> length() end
      assert rows.() == 50

      view |> element("button[phx-value-to='next']") |> render_click()

      assert render(view) =~ "51–61 of 61"
      assert rows.() == 11
    end

    test "no pager under a list that fits on one page", ctx do
      {:ok, _view, html} = live(ctx.conn, queue_path(ctx.project))

      refute html =~ "Page 1 of"
    end

    test "a placeholder where the number should be is marked", ctx do
      prospect_fixture(ctx.project, phone: "— look up —", email: nil, company: "Ace Roofing")

      {:ok, _view, html} = live(ctx.conn, queue_path(ctx.project))

      assert html =~ "no number"
    end
  end
end
