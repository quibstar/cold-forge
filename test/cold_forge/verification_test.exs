defmodule ColdForge.VerificationTest do
  # Not async: the API key is application config.
  use ColdForge.DataCase, async: false
  use Oban.Testing, repo: ColdForge.Repo

  import ColdForge.OutreachFixtures

  alias ColdForge.{Outreach, Repo, Sourcing, Verification}
  alias ColdForge.Outreach.{Enrollment, Prospect}
  alias ColdForge.Sourcing.Org
  alias ColdForge.Verification.Reoon
  alias ColdForge.Workers.VerifySweep

  setup do
    Application.put_env(:cold_forge, :reoon_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:cold_forge, :reoon_api_key) end)
    :ok
  end

  # Answers every single-address check with this verdict, and records what it
  # was asked so a test can see the mode and key went along.
  defp stub_verdict(status) do
    test = self()

    Req.Test.stub(Reoon, fn conn ->
      send(test, {:reoon, conn.request_path, Plug.Conn.fetch_query_params(conn).query_params})
      Req.Test.json(conn, %{"status" => status, "overall_score" => 3, "email" => "x"})
    end)
  end

  defp org_fixture(attrs \\ %{}) do
    base = %{
      name: "Summit Roofing LLC",
      segment: "roofing",
      provider: "places",
      source_ref: "place-#{System.unique_integer([:positive])}",
      website: "https://summitroofing.test",
      phone: "(616) 555-0101"
    }

    %Org{} |> Org.discovery_changeset(Map.merge(base, attrs)) |> Repo.insert!()
  end

  defp candidate(email),
    do: %{email: email, source_url: "https://summitroofing.test/contact", presentation: :mailto}

  defp found(org, email),
    do: Sourcing.record_found(org, candidate(email), %{has_contact_form: false})

  describe "check/1" do
    test "asks Reoon in power mode and returns the verdict" do
      stub_verdict("invalid")

      assert {:ok, "invalid"} = Verification.check("gone@roofer.test")
      assert_received {:reoon, "/api/v1/verify", params}
      assert params["mode"] == "power"
      assert params["email"] == "gone@roofer.test"
      assert params["key"] == "test-key"
    end

    test "is unchecked without a key, and doesn't call out" do
      Application.delete_env(:cold_forge, :reoon_api_key)
      assert Verification.check("a@roofer.test") == :unchecked
      refute_received {:reoon, _, _}
    end

    test "is unchecked when Reoon fails, rather than dropping the address" do
      Req.Test.stub(Reoon, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"status" => "error", "reason" => "x"})
      end)

      assert Verification.check("a@roofer.test") == :unchecked
    end
  end

  describe "the contact finder" do
    test "a mailbox that doesn't exist puts the place on the call list, address kept" do
      stub_verdict("invalid")
      {:ok, org} = found(org_fixture(), "gone@roofer.test")

      assert org.status == "rejected"
      assert org.reject_reason == "undeliverable_email"
      assert org.email == "gone@roofer.test"
      assert org.email_verdict == "invalid"
      assert org.email_checked_at
      assert Sourcing.view_of(org) == "phone"
    end

    test "a good or catch-all address is recorded for the drip with its verdict" do
      for verdict <- ["safe", "catch_all", "role_account", "unknown"] do
        stub_verdict(verdict)
        {:ok, org} = found(org_fixture(), "info@roofer.test")

        assert org.status == "fetched", verdict
        assert org.email_verdict == verdict
      end
    end

    test "without a key the address is recorded unchecked, as before" do
      Application.delete_env(:cold_forge, :reoon_api_key)
      {:ok, org} = found(org_fixture(), "info@roofer.test")

      assert org.status == "fetched"
      assert org.email_verdict == nil
    end

    test "promoting a place whose address failed makes a phone-only prospect" do
      stub_verdict("invalid")
      project = project_fixture()
      {:ok, org} = found(org_fixture(), "gone@roofer.test")

      assert {:ok, {prospect, _org}} = Sourcing.promote(org, project.id)
      assert prospect.email == nil
      assert prospect.phone == "(616) 555-0101"
    end

    test "promoting a checked good address carries the verdict to the prospect" do
      stub_verdict("safe")
      project = project_fixture()
      {:ok, org} = found(org_fixture(), "office@roofer.test")

      assert {:ok, {prospect, _org}} = Sourcing.promote(org, project.id)
      assert prospect.email == "office@roofer.test"
      assert prospect.email_verdict == "safe"
    end
  end

  describe "sweeping a project's drips" do
    setup do
      project = project_fixture()
      campaign = campaign_fixture(project)
      step_fixture(campaign)
      {:ok, campaign} = campaign |> Ecto.Changeset.change(status: "active") |> Repo.update()

      enroll = fn email ->
        prospect = prospect_fixture(project, %{email: email})
        {:ok, enrollment} = Outreach.enroll_prospect(campaign, prospect)
        {prospect, enrollment}
      end

      {gone, gone_e} = enroll.("gone@roofer.test")
      {good, good_e} = enroll.("Office@Roofer.test")
      {catchall, _} = enroll.("info@catchall.test")

      %{
        project: project,
        gone: gone,
        gone_e: gone_e,
        good: good,
        good_e: good_e,
        catchall: catchall
      }
    end

    test "start_sweep sends the unchecked addresses as one task and queues the wait", ctx do
      test = self()

      Req.Test.stub(Reoon, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:bulk, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"status" => "success", "task_id" => 777})
      end)

      assert {:ok, %{task_id: "777", count: 3}} = Verification.start_sweep(ctx.project.id)

      assert_received {:bulk, "/api/v1/create-bulk-verification-task/", body}

      assert Enum.sort(body["emails"]) ==
               ["gone@roofer.test", "info@catchall.test", "office@roofer.test"]

      assert body["key"] == "test-key"
      assert_enqueued(worker: VerifySweep, args: %{task_id: "777", project_id: ctx.project.id})
    end

    test "the worker waits while Reoon is still working", ctx do
      Req.Test.stub(Reoon, fn conn ->
        Req.Test.json(conn, %{"status" => "running", "progress_percentage" => 40.0})
      end)

      assert {:snooze, _} =
               perform_job(VerifySweep, %{task_id: "777", project_id: ctx.project.id})
    end

    test "results stop and suppress the undeliverable, and keep the rest sending", ctx do
      Req.Test.stub(Reoon, fn conn ->
        Req.Test.json(conn, %{
          "status" => "completed",
          "results" => %{
            "gone@roofer.test" => %{"status" => "invalid"},
            "office@roofer.test" => %{"status" => "safe"},
            "info@catchall.test" => %{"status" => "catch_all"}
          }
        })
      end)

      assert :ok = perform_job(VerifySweep, %{task_id: "777", project_id: ctx.project.id})

      gone_e = Repo.get!(Enrollment, ctx.gone_e.id)
      assert gone_e.status == "stopped"
      assert gone_e.stopped_reason == "undeliverable"
      assert Outreach.suppressed?("gone@roofer.test")
      assert Repo.get!(Prospect, ctx.gone.id).email_verdict == "invalid"

      assert Repo.get!(Enrollment, ctx.good_e.id).status == "active"
      refute Outreach.suppressed?("office@roofer.test")
      assert Repo.get!(Prospect, ctx.good.id).email_verdict == "safe"
      assert Repo.get!(Prospect, ctx.catchall.id).email_verdict == "catch_all"

      # Checked once: a second sweep has nobody left to send.
      assert Verification.sweep_candidates(ctx.project.id) == []
    end
  end
end
