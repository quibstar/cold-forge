defmodule ColdForge.Workers.ForwardReplyTest do
  use ColdForge.DataCase, async: true
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures
  import Swoosh.TestAssertions

  alias ColdForge.Workers.ForwardReply

  defp args(project, extra \\ %{}) do
    Map.merge(
      %{
        project_id: project.id,
        prospect_id: nil,
        from: "sam@riveraroofing.com",
        subject: "Re: Quick question",
        body: "Yes, send me the demo link."
      },
      extra
    )
  end

  test "sends a copy that answers the sender when replied to" do
    project = project_fixture(forward_replies_to: "kris@affordablestartup.com")

    assert :ok = perform_job(ForwardReply, args(project))

    assert_email_sent(fn email ->
      assert email.to == [{"", "kris@affordablestartup.com"}]
      assert email.reply_to == {"", "sam@riveraroofing.com"}
      assert email.subject == "Reply: Quick question"
      assert email.text_body =~ "Yes, send me the demo link."
      assert {_, from} = email.from
      assert from == project.from_email
    end)
  end

  test "does nothing when the project forwards nowhere" do
    project = project_fixture()

    assert :ok = perform_job(ForwardReply, args(project))
    assert_no_email_sent()
  end
end
