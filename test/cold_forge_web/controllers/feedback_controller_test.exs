defmodule ColdForgeWeb.FeedbackControllerTest do
  @moduledoc """
  Bounce and complaint handling is what keeps the SES account alive, and every
  case here is one SES actually sends. The two that matter most are the ones
  that must *not* suppress: a transient bounce is a full mailbox, and
  `not-spam` is a recipient rescuing the message from their spam folder.
  """
  use ColdForgeWeb.ConnCase, async: true

  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Outreach, Repo}
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

    %{project: project, prospect: prospect, enrollment: enrollment}
  end

  # SES never posts a bare payload — SNS wraps it, with the real content as a
  # JSON *string*. Every test goes through the envelope so the tests fail the
  # same way production would.
  defp sns(payload) do
    %{"Type" => "Notification", "Message" => Jason.encode!(payload)}
  end

  defp bounce(type, recipients, extra \\ %{}) do
    sns(%{
      "notificationType" => "Bounce",
      "bounce" =>
        Map.merge(
          %{
            "bounceType" => type,
            "bounceSubType" => "General",
            "bouncedRecipients" => Enum.map(recipients, &%{"emailAddress" => &1})
          },
          extra
        )
    })
  end

  defp complaint(recipients, extra \\ %{}) do
    sns(%{
      "notificationType" => "Complaint",
      "complaint" =>
        Map.merge(
          %{"complainedRecipients" => Enum.map(recipients, &%{"emailAddress" => &1})},
          extra
        )
    })
  end

  describe "authentication" do
    test "refuses a wrong secret", %{conn: conn} do
      conn =
        post(conn, ~p"/feedback/not-the-token", bounce("Permanent", ["sam@riveraroofing.com"]))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "a wrong secret suppresses nothing", ctx do
      post(ctx.conn, ~p"/feedback/not-the-token", bounce("Permanent", ["sam@riveraroofing.com"]))

      assert Outreach.list_suppressions() == []
      assert Repo.reload(ctx.prospect).status != "bounced"
    end
  end

  describe "permanent bounces" do
    test "suppress the address and stop the campaign", ctx do
      conn =
        post(ctx.conn, ~p"/feedback/#{@token}", bounce("Permanent", ["sam@riveraroofing.com"]))

      assert json_response(conn, 200) == %{"status" => "suppressed"}
      assert Outreach.suppressed?("sam@riveraroofing.com")
      assert Repo.reload(ctx.prospect).status == "bounced"
      assert Repo.reload(ctx.enrollment).status == "stopped"
    end

    test "record the diagnostic code, which is the only 'why' there is", ctx do
      post(
        ctx.conn,
        ~p"/feedback/#{@token}",
        bounce("Permanent", [], %{
          "bouncedRecipients" => [
            %{
              "emailAddress" => "sam@riveraroofing.com",
              "diagnosticCode" => "550 5.1.1 user unknown"
            }
          ]
        })
      )

      assert [suppression] = Outreach.list_suppressions()
      assert suppression.notes == "550 5.1.1 user unknown"
      assert suppression.reason == "bounced"
    end

    test "suppress an address with no prospect behind it", ctx do
      # SES reports bounces for addresses whose prospect has since been deleted.
      # The address must still never be written to again.
      conn = post(ctx.conn, ~p"/feedback/#{@token}", bounce("Permanent", ["gone@nowhere.test"]))

      assert json_response(conn, 200) == %{"status" => "suppressed"}
      assert Outreach.suppressed?("gone@nowhere.test")
    end

    test "stop the same address in every project it appears in", ctx do
      other = project_fixture(%{name: "Another idea"})
      twin = prospect_fixture(other, email: "sam@riveraroofing.com")

      post(ctx.conn, ~p"/feedback/#{@token}", bounce("Permanent", ["sam@riveraroofing.com"]))

      assert Repo.reload(ctx.prospect).status == "bounced"
      assert Repo.reload(twin).status == "bounced"
    end

    test "are idempotent, because SNS delivers at least once", ctx do
      payload = bounce("Permanent", ["sam@riveraroofing.com"])

      post(ctx.conn, ~p"/feedback/#{@token}", payload)
      conn = post(ctx.conn, ~p"/feedback/#{@token}", payload)

      assert json_response(conn, 200) == %{"status" => "suppressed"}
      assert length(Outreach.list_suppressions()) == 1
    end
  end

  describe "transient bounces" do
    test "do not suppress — the mailbox is full, not gone", ctx do
      conn =
        post(ctx.conn, ~p"/feedback/#{@token}", bounce("Transient", ["sam@riveraroofing.com"]))

      assert json_response(conn, 200) == %{"status" => "ignored"}
      refute Outreach.suppressed?("sam@riveraroofing.com")
      assert Repo.reload(ctx.prospect).status != "bounced"
      assert Repo.reload(ctx.enrollment).status == "active"
    end

    test "neither does an undetermined one", ctx do
      post(ctx.conn, ~p"/feedback/#{@token}", bounce("Undetermined", ["sam@riveraroofing.com"]))

      refute Outreach.suppressed?("sam@riveraroofing.com")
    end
  end

  describe "complaints" do
    test "suppress as complained and stop the campaign", ctx do
      conn = post(ctx.conn, ~p"/feedback/#{@token}", complaint(["sam@riveraroofing.com"]))

      assert json_response(conn, 200) == %{"status" => "suppressed"}
      assert [suppression] = Outreach.list_suppressions()
      assert suppression.reason == "complained"
      assert Repo.reload(ctx.prospect).status == "unsubscribed"
      assert Repo.reload(ctx.enrollment).status == "stopped"
    end

    test "'not-spam' is the opposite of a complaint and must not suppress", ctx do
      # The recipient moved the message *out* of their spam folder. Suppressing
      # here would drop the most engaged reader on the list.
      conn =
        post(
          ctx.conn,
          ~p"/feedback/#{@token}",
          complaint(["sam@riveraroofing.com"], %{"complaintFeedbackType" => "not-spam"})
        )

      assert json_response(conn, 200) == %{"status" => "ignored"}
      refute Outreach.suppressed?("sam@riveraroofing.com")
      assert Repo.reload(ctx.enrollment).status == "active"
    end
  end

  describe "SNS plumbing" do
    test "a subscription confirmation is acknowledged, never followed", ctx do
      conn =
        post(ctx.conn, ~p"/feedback/#{@token}", %{
          "Type" => "SubscriptionConfirmation",
          "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription"
        })

      assert json_response(conn, 200) == %{"status" => "confirmation_pending"}
    end

    test "deliveries and other event types are ignored", ctx do
      conn = post(ctx.conn, ~p"/feedback/#{@token}", sns(%{"notificationType" => "Delivery"}))

      assert json_response(conn, 200) == %{"status" => "ignored"}
      assert Outreach.list_suppressions() == []
    end

    test "the SES v2 spelling of the field works too", ctx do
      # Configuration-set event publishing says `eventType`; the older
      # notification path says `notificationType`. Both reach production.
      conn =
        post(
          ctx.conn,
          ~p"/feedback/#{@token}",
          sns(%{
            "eventType" => "Bounce",
            "bounce" => %{
              "bounceType" => "Permanent",
              "bouncedRecipients" => [%{"emailAddress" => "sam@riveraroofing.com"}]
            }
          })
        )

      assert json_response(conn, 200) == %{"status" => "suppressed"}
      assert Outreach.suppressed?("sam@riveraroofing.com")
    end
  end
end
