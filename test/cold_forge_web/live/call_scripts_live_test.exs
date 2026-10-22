defmodule ColdForgeWeb.CallScriptsLiveTest do
  @moduledoc """
  The script panel beside the call, and the form that edits it.

  This is the half of the ExteriorPro move that had to be built rather than
  copied: the scripts came across as data, but a call list you can't read a
  script off while the phone is ringing is a worse tool than the one it
  replaced.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro", phone: "(616) 555-0142")

    scripted =
      prospect_fixture(project,
        email: nil,
        phone: "(616) 779-5824",
        company: "Moore & Sons Roofing",
        first_name: nil,
        last_name: nil,
        custom_fields: %{
          "opener" => "Is the owner in?",
          "voicemail" => "Hey, it's just Kris.",
          "script_direct" => "Straight pitch, thirty seconds.",
          "city" => "Grand Rapids",
          "fit" => "High"
        }
      )

    %{conn: log_in_user(conn, user_fixture()), project: project, scripted: scripted}
  end

  defp calls_path(project), do: ~p"/admin/p/#{project.id}/calls"

  describe "the script panel" do
    test "shows the script written for this shop once you select them", ctx do
      {:ok, view, _html} = live(ctx.conn, calls_path(ctx.project))

      html = view |> element("button[phx-value-id='#{ctx.scripted.id}']") |> render_click()

      assert html =~ "What to say"
      assert html =~ "Is the owner in?"
      assert html =~ "Hey, it&#39;s just Kris."
    end

    test "only draws tabs there is a script for", ctx do
      {:ok, view, _html} = live(ctx.conn, calls_path(ctx.project))
      view |> element("button[phx-value-id='#{ctx.scripted.id}']") |> render_click()

      assert has_element?(view, "button[phx-value-tab='original']")
      assert has_element?(view, "button[phx-value-tab='direct']")
      # Nothing was written for the NEPQ script, so there is no tab to click
      # into and find empty.
      refute has_element?(view, "button[phx-value-tab='nepq']")
    end

    test "switching tabs swaps the script without leaving the queue", ctx do
      {:ok, view, _html} = live(ctx.conn, calls_path(ctx.project))
      view |> element("button[phx-value-id='#{ctx.scripted.id}']") |> render_click()

      html = view |> element("button[phx-value-tab='direct']") |> render_click()

      assert html =~ "Straight pitch, thirty seconds."
      refute html =~ "Is the owner in?"
      # Still the same screen, queue and all.
      assert has_element?(view, "button[phx-value-id='#{ctx.scripted.id}']")
    end

    test "no script means no panel, not an empty one", ctx do
      bare = prospect_fixture(ctx.project, phone: "(616) 555-0199", email: nil)

      {:ok, view, _html} = live(ctx.conn, calls_path(ctx.project))
      html = view |> element("button[phx-value-id='#{bare.id}']") |> render_click()

      refute html =~ "What to say"
    end
  end

  describe "the queue" do
    test "shows the fit grade it is ordered by, and where they are", ctx do
      {:ok, _view, html} = live(ctx.conn, calls_path(ctx.project))

      assert html =~ "High"
      assert html =~ "Grand Rapids"
    end

    test "best fit first among people nobody has rung", ctx do
      low =
        prospect_fixture(ctx.project, phone: "(616) 555-0111", custom_fields: %{"fit" => "Low"})

      medium =
        prospect_fixture(ctx.project,
          phone: "(616) 555-0122",
          custom_fields: %{"fit" => "Medium"}
        )

      ids = ctx.project.id |> ColdForge.Calling.queue() |> Enum.map(& &1.id)

      assert Enum.take(ids, 3) == [ctx.scripted.id, medium.id, low.id]
    end

    test "a placeholder where the number should be is marked, not offered", ctx do
      no_number =
        prospect_fixture(ctx.project, phone: "— look up —", email: nil, company: "Ace Roofing")

      {:ok, view, html} = live(ctx.conn, calls_path(ctx.project))
      assert html =~ "no number"

      panel = view |> element("button[phx-value-id='#{no_number.id}']") |> render_click()

      # A tel: link around "— look up —" is dead but looks live.
      refute panel =~ ~s|href="tel:— look up —"|
      assert panel =~ "No number"
    end

    test "a real number is offered as a tel: link", ctx do
      {:ok, view, _html} = live(ctx.conn, calls_path(ctx.project))
      panel = view |> element("button[phx-value-id='#{ctx.scripted.id}']") |> render_click()

      assert panel =~ ~s|href="tel:(616) 779-5824"|
    end
  end

  describe "editing a prospect's scripts" do
    test "the form shows each script in a box of its own", ctx do
      {:ok, _view, html} =
        live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects/#{ctx.scripted.id}/edit")

      assert html =~ "Call scripts"
      assert html =~ ~s|name="prospect[call_scripts][opener]"|
      assert html =~ "Is the owner in?"
      # Not in the one-per-line box, which cannot hold a page of prose.
      refute html =~ "opener: Is the owner in?"
    end

    test "the one-per-line box holds the extras and only the extras", ctx do
      {:ok, _view, html} =
        live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects/#{ctx.scripted.id}/edit")

      assert html =~ "city: Grand Rapids"
      assert html =~ "fit: High"
    end

    test "saving the form keeps both halves", ctx do
      {:ok, view, _html} =
        live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects/#{ctx.scripted.id}/edit")

      view
      |> form("#prospect-form",
        prospect: %{
          "company" => "Moore & Sons Roofing",
          "phone" => "(616) 779-5824",
          "custom_fields_text" => "city: Kalamazoo\nfit: High",
          "call_scripts" => %{
            "opener" => "A reworked opener.\n\nWith a second line: and a colon.",
            "voicemail" => "Hey, it's just Kris.",
            "script_direct" => "Straight pitch, thirty seconds.",
            "problem_question" => "",
            "objections" => "",
            "script_nepq" => ""
          }
        }
      )
      |> render_submit()

      reloaded = Outreach.get_prospect!(ctx.scripted.id)

      assert reloaded.custom_fields["opener"] ==
               "A reworked opener.\n\nWith a second line: and a colon."

      assert reloaded.custom_fields["city"] == "Kalamazoo"
      assert reloaded.custom_fields["script_direct"] == "Straight pitch, thirty seconds."
    end
  end
end
