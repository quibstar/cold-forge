defmodule ColdForgeWeb.CallScriptsLiveTest do
  @moduledoc """
  The call page — the script beside the phone, the debrief after it — and the
  queue that leads there.

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
          "state" => "MI",
          "fit" => "High",
          "current_software" => "Jobber",
          "employee_estimate" => "6-10"
        }
      )

    %{conn: log_in_user(conn, user_fixture()), project: project, scripted: scripted}
  end

  defp queue_path(project), do: ~p"/admin/p/#{project.id}/calls"
  defp call_path(project, prospect), do: ~p"/admin/p/#{project.id}/calls/#{prospect.id}"

  describe "the queue" do
    test "each row links to that prospect's own page", ctx do
      {:ok, view, _html} = live(ctx.conn, queue_path(ctx.project))

      # A link, not a panel that opens below fifty rows of queue.
      assert view
             |> element("#queue-#{ctx.scripted.id}")
             |> render_click() ==
               {:error,
                {:live_redirect, %{kind: :push, to: call_path(ctx.project, ctx.scripted)}}}
    end

    test "shows the fit grade it is ordered by, and where they are", ctx do
      {:ok, _view, html} = live(ctx.conn, queue_path(ctx.project))

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

      ids = ctx.project.id |> Calling.queue() |> Enum.map(& &1.id)

      assert Enum.take(ids, 3) == [ctx.scripted.id, medium.id, low.id]
    end

    test "a placeholder where the number should be is marked in the list", ctx do
      prospect_fixture(ctx.project, phone: "— look up —", email: nil, company: "Ace Roofing")

      {:ok, _view, html} = live(ctx.conn, queue_path(ctx.project))

      assert html =~ "no number"
    end
  end

  describe "the script on the call page" do
    test "shows the script written for this shop", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert html =~ "What to say"
      assert html =~ "Is the owner in?"
      assert html =~ "Hey, it&#39;s just Kris."
    end

    test "only draws tabs there is a script for", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert has_element?(view, "button[phx-value-tab='original']")
      assert has_element?(view, "button[phx-value-tab='direct']")
      # Nothing was written for the NEPQ script, so there is no tab to click
      # into and find empty.
      refute has_element?(view, "button[phx-value-tab='nepq']")
    end

    test "switching tabs swaps the script without leaving the page", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      html = view |> element("button[phx-value-tab='direct']") |> render_click()

      assert html =~ "Straight pitch, thirty seconds."
      refute html =~ "Is the owner in?"
      assert has_element?(view, "#log-call-form")
    end

    test "no script means no panel, not an empty one", ctx do
      bare = prospect_fixture(ctx.project, phone: "(616) 555-0199", email: nil)

      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, bare))

      refute html =~ "What to say"
    end
  end

  describe "the calling card" do
    test "a real number is offered as a tel: link", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert html =~ ~s|href="tel:(616) 779-5824"|
    end

    test "a placeholder is not", ctx do
      no_number =
        prospect_fixture(ctx.project, phone: "— look up —", email: nil, company: "Ace Roofing")

      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, no_number))

      refute html =~ ~s|href="tel:— look up —"|
      assert html =~ "no number"
    end

    test "shows what came across from the call sheet", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert html =~ "Grand Rapids, MI"
      assert html =~ "Jobber"
      assert html =~ "6-10"
    end

    test "the status can be set by hand", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view |> form("#prospect-status", %{"status" => "replied"}) |> render_change()

      assert Outreach.get_prospect!(ctx.scripted.id).status == "replied"
    end
  end

  describe "logging a call" do
    test "the debrief is part of the same form as the notes", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert html =~ "Pain debrief"
      assert html =~ ~s|name="call[pain]"|
      assert html =~ ~s|name="call[what_they_like]"|
      assert html =~ ~s|name="call[severity]"|
    end

    test "what was said is kept, not just that a call happened", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view
      |> form("#log-call-form",
        call: %{
          "outcome" => "connected",
          "notes" => "Caught him on a roof.",
          "current_software" => "Jobber",
          "what_they_like" => "The scheduling board.",
          "pain" => "Quotes take two days to get out.",
          "category" => "Estimating/Billing",
          "severity" => "4",
          "switch_objection" => "Mid-contract until March."
        }
      )
      |> render_submit()

      assert [call] = Calling.list_calls(ctx.scripted.id)
      assert call.outcome == "connected"
      assert call.notes == "Caught him on a roof."
      assert call.pain == "Quotes take two days to get out."
      assert call.category == "Estimating/Billing"
      assert call.severity == 4
      assert call.switch_objection == "Mid-contract until March."
    end

    test "a date they gave you beats the cadence", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view
      |> form("#log-call-form", call: %{"outcome" => "no_answer", "next_call_on" => "2026-11-03"})
      |> render_submit()

      # Nine in the morning in the project's timezone, not midnight UTC, which
      # would make the row due the evening before.
      assert Outreach.get_prospect!(ctx.scripted.id).next_call_at == ~U[2026-11-03 13:00:00Z]
    end

    test "without a date, the cadence decides", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view
      |> form("#log-call-form", call: %{"outcome" => "no_answer", "next_call_on" => ""})
      |> render_submit()

      next = Outreach.get_prospect!(ctx.scripted.id).next_call_at
      assert DateTime.diff(next, DateTime.utc_now(), :day) in [1, 2]
    end

    test "sending the demo stops the cold sequence, like a conversation does", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view |> form("#log-call-form", call: %{"outcome" => "demo_sent"}) |> render_submit()

      assert Outreach.get_prospect!(ctx.scripted.id).status == "replied"
    end

    test "a gatekeeper is not a conversation", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view |> form("#log-call-form", call: %{"outcome" => "gatekeeper"}) |> render_submit()

      prospect = Outreach.get_prospect!(ctx.scripted.id)
      assert prospect.status == "new"
      # Rescheduled on the cadence, same as a no-answer.
      assert prospect.next_call_at
    end
  end

  describe "history" do
    setup ctx do
      {:ok, call} =
        Calling.log_call(ctx.scripted, %{
          "outcome" => "connected",
          "notes" => "Caught him on a roof.",
          "pain" => "Quotes take two days."
        })

      Map.put(ctx, :call, call)
    end

    test "shows what was said, not just that a call happened", ctx do
      {:ok, _view, html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      assert html =~ "Spoke to them"
      assert html =~ "Caught him on a roof."
      assert html =~ "Quotes take two days."
    end

    test "a call logged against the wrong company can be corrected", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))

      view
      |> element("button[phx-click='edit_call'][phx-value-id='#{ctx.call.id}']")
      |> render_click()

      view
      |> form("#edit-call-#{ctx.call.id}",
        call: %{"outcome" => "voicemail", "notes" => "Actually just a voicemail."}
      )
      |> render_submit()

      assert [call] = Calling.list_calls(ctx.scripted.id)
      assert call.outcome == "voicemail"
      assert call.notes == "Actually just a voicemail."
    end

    test "deleting one puts the attempt count back", ctx do
      {:ok, view, _html} = live(ctx.conn, call_path(ctx.project, ctx.scripted))
      assert Outreach.get_prospect!(ctx.scripted.id).call_attempts == 1

      view
      |> element("button[phx-click='delete_call'][phx-value-id='#{ctx.call.id}']")
      |> render_click()

      prospect = Outreach.get_prospect!(ctx.scripted.id)
      assert Calling.list_calls(ctx.scripted.id) == []
      assert prospect.call_attempts == 0
      # Otherwise the prospect goes on claiming a conversation that no longer
      # exists, and the cadence counts an attempt that never happened.
      assert prospect.last_called_at == nil
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
