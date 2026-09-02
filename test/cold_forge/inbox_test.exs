defmodule ColdForge.InboxTest do
  @moduledoc """
  Reply matching, and the two ways it can be wrong: missing a real reply, so
  somebody who answered keeps getting chased; or treating an out-of-office as
  one, so people silently drop out of campaigns while on holiday.
  """
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Inbox, Outreach}
  alias ColdForge.Workers.SendMessage

  # A campaign with a follow-up, sent to one prospect — so there is something
  # left for a reply to stop.
  setup do
    project = project_fixture()
    campaign = campaign_fixture(project)
    step_fixture(campaign, %{"subject" => "Quick question", "body" => "Hi {{first_name}}"})
    step_fixture(campaign, %{"subject" => "Re", "body" => "Bumping", "delay_days" => 3})
    campaign = Outreach.get_campaign!(campaign.id)

    prospect = prospect_fixture(project, email: "sam@riveraroofing.com", first_name: "Sam")
    {:ok, _} = Outreach.send_campaign(campaign, [prospect.id])
    [enrollment] = Outreach.list_enrollments(campaign.id)
    :ok = perform_job(SendMessage, %{enrollment_id: enrollment.id})

    [message] = Outreach.list_messages(project.id)

    %{
      project: project,
      campaign: campaign,
      prospect: prospect,
      message: message,
      enrollment: enrollment
    }
  end

  describe "the outgoing Message-ID" do
    test "is set, and is ours rather than the provider's", ctx do
      assert ctx.message.rfc_message_id
      # Qualified with the sending domain — a Message-ID whose right-hand side
      # doesn't resolve to the sender is a spam signal.
      assert String.ends_with?(ctx.message.rfc_message_id, "@exteriorpro.io")
      assert String.starts_with?(ctx.message.rfc_message_id, ctx.message.id)
    end
  end

  describe "matching" do
    test "In-Reply-To names the exact send", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "Sam Rivera <sam@riveraroofing.com>",
          subject: "Re: Quick question",
          body: "Sure, send it over.",
          in_reply_to: "<#{ctx.message.rfc_message_id}>"
        })

      assert reply.matched_by == "exact"
      assert reply.message_id == ctx.message.id
      assert reply.prospect_id == ctx.prospect.id
      # The display name is stripped off the address.
      assert reply.from_email == "sam@riveraroofing.com"
    end

    test "References matches a reply further down a thread", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Re: Quick question",
          references: "<someone-elses@example.com> <#{ctx.message.rfc_message_id}>"
        })

      assert reply.matched_by == "exact"
      assert reply.message_id == ctx.message.id
    end

    test "falls back to the From address when no header names us", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{from: "sam@riveraroofing.com", subject: "hello"})

      # Weaker on purpose: it says who wrote, not what they answered.
      assert reply.matched_by == "address"
      assert reply.message_id == nil
      assert reply.prospect_id == ctx.prospect.id
    end

    test "mail from a stranger is ignored, not an error" do
      assert {:error, :no_match} =
               Inbox.receive_email(%{from: "nobody@elsewhere.com", subject: "hi"})
    end

    test "a redelivered webhook does not record a second reply", ctx do
      params = %{
        from: "sam@riveraroofing.com",
        subject: "Re: Quick question",
        in_reply_to: "<#{ctx.message.rfc_message_id}>",
        external_id: "provider-abc"
      }

      {:ok, _} = Inbox.receive_email(params)
      assert {:ok, :duplicate} = Inbox.receive_email(params)

      assert length(Inbox.list_replies_for_prospect(ctx.prospect.id)) == 1
    end
  end

  describe "what a reply does" do
    test "stops the campaign and marks the prospect", ctx do
      {:ok, _} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          in_reply_to: "<#{ctx.message.rfc_message_id}>"
        })

      assert Repo.reload(ctx.prospect).status == "replied"

      enrollment = Repo.reload(ctx.enrollment)
      assert enrollment.status == "stopped"
      assert enrollment.stopped_reason == "replied"
      assert enrollment.next_send_at == nil
    end

    test "replying does not add them to the do-not-contact list", ctx do
      {:ok, _} = Inbox.receive_email(%{from: "sam@riveraroofing.com"})

      # Answering the phone is not the same as asking never to be called.
      refute Outreach.suppressed?(ctx.prospect.email)
    end
  end

  describe "automated mail" do
    test "an out-of-office is recorded but stops nothing", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Automatic reply: Quick question",
          in_reply_to: "<#{ctx.message.rfc_message_id}>"
        })

      assert reply.automated
      # They were away, not interested — the campaign carries on.
      assert Repo.reload(ctx.prospect).status == "new"
      assert Repo.reload(ctx.enrollment).status == "active"
    end

    test "recognises RFC 3834 headers", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Re: Quick question",
          headers: %{"Auto-Submitted" => "auto-replied"}
        })

      assert reply.automated
      _ = ctx
    end

    test "a bounce notice is not a reply", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Undeliverable: Quick question"
        })

      assert reply.automated
      _ = ctx
    end

    test "a real reply that merely mentions being away is not automated", ctx do
      {:ok, reply} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Re: Quick question",
          body: "I'm on leave next week but yes, send it over."
        })

      # Erring toward "a person wrote this": mistaking a real reply for an
      # autoresponder means chasing someone who already answered.
      refute reply.automated
      assert Repo.reload(ctx.prospect).status == "replied"
    end
  end

  describe "counting" do
    test "counts people, not messages, and ignores robots", ctx do
      {:ok, _} = Inbox.receive_email(%{from: "sam@riveraroofing.com", external_id: "a"})
      {:ok, _} = Inbox.receive_email(%{from: "sam@riveraroofing.com", external_id: "b"})

      {:ok, _} =
        Inbox.receive_email(%{
          from: "sam@riveraroofing.com",
          subject: "Out of office",
          external_id: "c"
        })

      assert Inbox.replied_count(ctx.project.id) == 1
      assert length(Inbox.list_replies(ctx.project.id)) == 3
    end
  end
end
