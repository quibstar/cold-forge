defmodule ColdForgeWeb.AdminLiveTest do
  @moduledoc """
  Walks every admin screen. A route that 404s or a LiveView that raises on
  mount is invisible until somebody clicks it, which is exactly the failure
  these catch.
  """
  use ColdForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ColdForge.AccountsFixtures
  import ColdForge.OutreachFixtures

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Project

  setup %{conn: conn} do
    project = project_fixture(name: "ExteriorPro")
    campaign = campaign_fixture(project)
    step = step_fixture(campaign)
    prospect = prospect_fixture(project, first_name: "Dana", company: "Northside Siding")

    %{
      conn: log_in_user(conn, user_fixture()),
      project: project,
      campaign: campaign,
      step: step,
      prospect: prospect
    }
  end

  test "the admin requires a signed-in operator" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
  end

  test "dashboard lists projects with their counters", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "ExteriorPro"
    assert html =~ "Dashboard"
  end

  test "every sidebar destination renders", ctx do
    paths = [
      ~p"/admin",
      ~p"/admin/projects",
      ~p"/admin/projects/new",
      ~p"/admin/suppressions",
      ~p"/admin/guide",
      ~p"/admin/p/#{ctx.project.id}/prospects",
      ~p"/admin/p/#{ctx.project.id}/prospects/new",
      ~p"/admin/p/#{ctx.project.id}/prospects/#{ctx.prospect.id}/edit",
      ~p"/admin/p/#{ctx.project.id}/prospects/import",
      ~p"/admin/p/#{ctx.project.id}",
      ~p"/admin/p/#{ctx.project.id}/campaigns/new",
      ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}",
      ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/people",
      ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/emails/new",
      ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/emails/#{ctx.step.id}",
      ~p"/admin/p/#{ctx.project.id}/activity"
    ]

    for path <- paths do
      assert {:ok, _view, _html} = live(ctx.conn, path), "#{path} failed to render"
    end
  end

  describe "navigating into a project" do
    test "the projects list links into each project", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/admin/projects")
      assert html =~ ~s|href="/admin/p/#{ctx.project.id}"|
    end

    test "a project shows its three tabs", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}")

      assert html =~ ~s|href="/admin/p/#{ctx.project.id}"|
      assert html =~ ~s|href="/admin/p/#{ctx.project.id}/prospects"|
      assert html =~ ~s|href="/admin/p/#{ctx.project.id}/activity"|
    end

    test "the trail down to an email says where you are", ctx do
      {:ok, _view, html} =
        live(
          ctx.conn,
          ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/emails/#{ctx.step.id}"
        )

      assert html =~ "Projects"
      assert html =~ ctx.project.name
      assert html =~ ctx.campaign.name
      assert html =~ "Email 1"
    end
  end

  describe "search palette" do
    test "finds a prospect from anywhere, not just its own project", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/suppressions")

      html = view |> element("header button", "Search") |> render_click()

      assert html =~ "Search everything"

      html =
        view
        |> form("#search-palette-form", %{"q" => "Northside"})
        |> render_change()

      assert html =~ "Dana Rivera"
      assert html =~ "Northside Siding"
    end
  end

  describe "campaign editor" do
    test "refuses to start a campaign with no emails", ctx do
      empty = campaign_fixture(ctx.project, name: "Empty")
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/campaigns/#{empty.id}")

      html = view |> element("button", "Start") |> render_click()

      assert html =~ "Write at least one email"
      assert Outreach.get_campaign!(empty.id).status == "draft"
    end

    test "previews the email as it will actually be sent", ctx do
      {:ok, _view, html} =
        live(
          ctx.conn,
          ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/emails/#{ctx.step.id}"
        )

      # Merge tags resolved, not shown raw.
      assert html =~ "Quick question about Northside Siding"
      assert html =~ "Hi Dana,"
      # And the parts the old preview didn't show: the tokenised link and the
      # compliance footer that get added on send.
      assert html =~ "/c/preview0"
      assert html =~ "Unsubscribe"
    end
  end

  describe "email preview" do
    test "previewing a step from the campaign page shows the sent form", ctx do
      {:ok, view, html} =
        live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}")

      refute html =~ "Plain-text part"

      html = view |> element("button[phx-click='preview_email']") |> render_click()

      # Merge tags resolved, link tokenised, footer attached — the whole point
      # of previewing rather than re-reading the body.
      assert html =~ "Quick question about Northside Siding"
      assert html =~ "/c/preview0"
      assert html =~ "Unsubscribe"

      html = view |> element("button[phx-click='close_preview']") |> render_click()
      refute html =~ "modal-open"
    end
  end

  describe "project branding" do
    test "an uploaded logo becomes an absolute URL in the email", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          logo_path: "/uploads/logos/abc.png",
          brand_color: "#0f766e"
        })

      # A mail client fetches this from the open internet with no page to
      # resolve a relative path against.
      assert Project.logo_src(project, "https://cold.example") ==
               "https://cold.example/uploads/logos/abc.png"
    end

    test "an uploaded logo wins over a typed URL", ctx do
      {:ok, project} =
        Outreach.update_project(ctx.project, %{
          logo_url: "https://elsewhere.example/old.png",
          logo_path: "/uploads/logos/new.png"
        })

      assert Project.logo_src(project, "https://cold.example") =~ "new.png"
    end
  end

  describe "survey preview" do
    setup ctx do
      {:ok, survey} =
        ColdForge.Survey.create_survey(%{project_id: ctx.project.id, name: "What hurts"})

      {:ok, _q} =
        ColdForge.Survey.create_question(survey, %{
          "position" => 1,
          "kind" => "choice",
          "prompt" => "Worst bit?",
          "options" => "Scheduling\nInvoicing"
        })

      %{survey: survey}
    end

    test "shows the real answer page, inert", ctx do
      conn = get(ctx.conn, ~p"/admin/p/#{ctx.project.id}/surveys/#{ctx.survey.id}/preview")
      html = html_response(conn, 200)

      assert html =~ "Worst bit?"
      assert html =~ "Scheduling"
      # The recipient arrives having clicked an answer, so it starts selected.
      assert html =~ "checked"
      # And nothing here can be submitted.
      assert html =~ "disabled"
      assert html =~ "nothing is recorded"
    end

    test "previewing records no answer and creates no link", ctx do
      get(ctx.conn, ~p"/admin/p/#{ctx.project.id}/surveys/#{ctx.survey.id}/preview")

      assert ColdForge.Survey.answered_count(ctx.survey.id) == 0
      assert ColdForge.Repo.aggregate(ColdForge.Survey.Link, :count) == 0
    end

    test "the preview needs a signed-in operator", ctx do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/admin/p/#{ctx.project.id}/surveys/#{ctx.survey.id}/preview")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "markup that browsers reject" do
    # A `<select>` may only contain `<option>` and `<optgroup>`. Anything else —
    # a hidden input, most temptingly — is dropped by the parser along with
    # every option that follows it, leaving an empty dropdown. It looks like
    # valid markup in a string assertion, which is why this checks structure.
    test "no select contains an input", ctx do
      paths = [
        ~p"/admin/p/#{ctx.project.id}/prospects",
        ~p"/admin/p/#{ctx.project.id}/campaigns/#{ctx.campaign.id}/emails/new",
        ~p"/admin/projects/new"
      ]

      for path <- paths do
        {:ok, _view, html} = live(ctx.conn, path)
        assert_selects_are_clean(html, path)
      end
    end

    test "the CSV column mapping renders options inside its selects", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects/import")

      csv = "Email,First Name\nsam@example.com,Sam\n"

      entry =
        file_input(view, "#csv-upload-form", :csv, [
          %{name: "leads.csv", content: csv, type: "text/csv"}
        ])

      render_upload(entry, "leads.csv")
      html = view |> element("#csv-upload-form") |> render_submit()

      assert_selects_are_clean(html, "import mapping")

      # And the guessed column is actually offered, pre-selected.
      assert html =~ ~r{<option value="0"[^>]*selected[^>]*>\s*Email\s*</option>}
    end
  end

  # Every `<select>` must still contain its options once the HTML has been
  # parsed. Checking for a stray `<input>` inside one does not work: the parser
  # has already ejected it — along with every option after it — which is
  # precisely the damage. An empty select is what that damage looks like.
  defp assert_selects_are_clean(html, where) do
    ~r{<select\b[^>]*>(.*?)</select>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.each(fn [inner] ->
      assert inner =~ ~r{<option\b},
             "a <select> on #{where} rendered with no options — something invalid inside it " <>
               "(an <input>, most likely) made the parser drop them"
    end)
  end

  describe "csv import" do
    test "walks upload, mapping and review without writing until committed", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects/import")
      assert html =~ "Drop a CSV here"

      csv = """
      Email,First Name,Company,Roof Type
      marcus@webbroofing.com,Marcus,Webb Roofing,Asphalt
      dana@northsidesiding.com,Dana,Northside,Metal
      """

      entry =
        file_input(view, "#csv-upload-form", :csv, [
          %{name: "leads.csv", content: csv, type: "text/csv"}
        ])

      render_upload(entry, "leads.csv")
      html = view |> element("#csv-upload-form") |> render_submit()

      # Mapping step: guessed from the headers.
      assert html =~ "Map the columns"
      assert html =~ "Roof Type"

      before = length(Outreach.list_prospects(ctx.project.id))
      html = view |> element("button", "Review import") |> render_click()

      # Review step reports what *would* happen, having written nothing.
      assert html =~ "Will be added"
      assert length(Outreach.list_prospects(ctx.project.id)) == before

      view |> element("button[phx-click='commit']") |> render_click()

      emails = Outreach.list_prospects(ctx.project.id) |> Enum.map(& &1.email)
      assert "marcus@webbroofing.com" in emails
      assert "dana@northsidesiding.com" in emails

      # Unmapped columns survive the round trip as merge-tag data.
      marcus =
        Enum.find(
          Outreach.list_prospects(ctx.project.id),
          &(&1.email == "marcus@webbroofing.com")
        )

      assert marcus.custom_fields == %{"roof_type" => "Asphalt"}
    end
  end

  test "the guide renders", ctx do
    {:ok, _view, html} = live(ctx.conn, ~p"/admin/guide")
    assert html =~ "How this works"
    assert html =~ "Do not contact"
  end

  describe "prospects" do
    test "unsubscribing from the list suppresses globally", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")

      view
      |> element("button[phx-value-id='#{ctx.prospect.id}']", "Unsubscribe")
      |> render_click()

      assert Outreach.suppressed?(ctx.prospect.email)
    end

    test "search filters the list", ctx do
      prospect_fixture(ctx.project, first_name: "Zed", company: "Zenith Gutters")
      {:ok, view, _html} = live(ctx.conn, ~p"/admin/p/#{ctx.project.id}/prospects")

      html =
        view
        |> form("#prospect-filters", %{"search" => "Zenith", "status" => "all"})
        |> render_change()

      assert html =~ "Zenith Gutters"
      refute html =~ "Northside Siding"
    end
  end
end
