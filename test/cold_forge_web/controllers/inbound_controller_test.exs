defmodule ColdForgeWeb.InboundControllerTest do
  @moduledoc """
  The inbound endpoint is reachable by anyone who finds the path, so the shape
  of what it accepts and refuses matters more than most.
  """
  use ColdForgeWeb.ConnCase, async: true

  alias ColdForge.Repo
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Inbox, Outreach}
  alias ColdForge.Workers.SendMessage

  @token "test-inbound-token"

  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step_fixture(campaign, %{"subject" => "Quick question", "body" => "Hi"})
    step_fixture(campaign, %{"subject" => "Re", "body" => "Bump", "delay_days" => 3})
    campaign = Outreach.get_campaign!(campaign.id)

    prospect = prospect_fixture(project, email: "sam@riveraroofing.com")
    {:ok, _} = Outreach.send_campaign(campaign, [prospect.id])
    [enrollment] = Outreach.list_enrollments(campaign.id)
    :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})
    [message] = Outreach.list_messages(project.id)

    %{project: project, prospect: prospect, message: message, enrollment: enrollment}
  end

  describe "authentication" do
    test "refuses a wrong secret", %{conn: conn} do
      conn = post(conn, ~p"/inbound/not-the-token", %{"from" => "sam@riveraroofing.com"})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "a wrong secret records nothing", ctx do
      post(ctx.conn, ~p"/inbound/not-the-token", %{"from" => "sam@riveraroofing.com"})

      assert Inbox.list_replies(ctx.project.id) == []
      assert Repo.reload(ctx.prospect).status == "new"
    end
  end

  describe "recording a reply" do
    test "matches on In-Reply-To and stops the campaign", ctx do
      conn =
        post(ctx.conn, ~p"/inbound/#{@token}", %{
          "from" => "Sam Rivera <sam@riveraroofing.com>",
          "subject" => "Re: Quick question",
          "text" => "Yes, send it over.",
          "In-Reply-To" => "<#{ctx.message.rfc_message_id}>",
          "MessageID" => "provider-1"
        })

      assert json_response(conn, 200) == %{"status" => "recorded", "matched_by" => "exact"}
      assert Repo.reload(ctx.prospect).status == "replied"
      assert Repo.reload(ctx.enrollment).status == "stopped"
    end

    test "reads the SES/SNS shape as happily as a flat one", ctx do
      conn =
        post(ctx.conn, ~p"/inbound/#{@token}", %{
          "mail" => %{
            "source" => "sam@riveraroofing.com",
            "messageId" => "ses-1",
            "commonHeaders" => %{"subject" => "Re: Quick question"},
            "headers" => [
              %{"name" => "In-Reply-To", "value" => "<#{ctx.message.rfc_message_id}>"}
            ]
          }
        })

      assert %{"matched_by" => "exact"} = json_response(conn, 200)
    end

    test "mail from a stranger is accepted and ignored", ctx do
      conn = post(ctx.conn, ~p"/inbound/#{@token}", %{"from" => "nobody@elsewhere.com"})

      # A 200 so the provider stops retrying something that will never match.
      assert json_response(conn, 200) == %{"status" => "ignored"}
      assert Inbox.list_replies(ctx.project.id) == []
    end

    test "a redelivery is a no-op", ctx do
      params = %{
        "from" => "sam@riveraroofing.com",
        "In-Reply-To" => "<#{ctx.message.rfc_message_id}>",
        "MessageID" => "provider-retry"
      }

      post(ctx.conn, ~p"/inbound/#{@token}", params)
      conn = post(ctx.conn, ~p"/inbound/#{@token}", params)

      assert json_response(conn, 200) == %{"status" => "duplicate"}
      assert length(Inbox.list_replies(ctx.project.id)) == 1
    end

    test "an out-of-office is recorded without stopping anything", ctx do
      conn =
        post(ctx.conn, ~p"/inbound/#{@token}", %{
          "from" => "sam@riveraroofing.com",
          "subject" => "Automatic reply: Quick question",
          "In-Reply-To" => "<#{ctx.message.rfc_message_id}>"
        })

      assert json_response(conn, 200)
      assert Repo.reload(ctx.prospect).status == "new"
      assert Repo.reload(ctx.enrollment).status == "active"
    end
  end
end
