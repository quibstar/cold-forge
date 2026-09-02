# Dev seed: an operator account plus one project wired end-to-end, so the drip
# can be exercised without clicking through setup first.
#
#     mix run priv/repo/seeds.exs

alias ColdForge.{Accounts, Outreach, Repo}

email = "quibstar@gmail.com"

unless Accounts.get_user_by_email(email) do
  {:ok, user} = Accounts.register_user(%{email: email})

  # phx.gen.auth users start unconfirmed and passwordless; confirming here means
  # the magic-link flow in dev works from the first run.
  user
  |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
  |> Repo.update!()

  IO.puts("Created operator #{email} — log in at /users/log-in")
end

project =
  Outreach.get_project_by_slug("exteriorpro") ||
    (
      {:ok, project} =
        Outreach.create_project(%{
          name: "ExteriorPro",
          slug: "exteriorpro",
          from_name: "Kris Utter",
          from_email: "kris@exteriorpro.io",
          landing_url: "https://exteriorpro.io/demo",
          postal_address: "ExteriorPro · 123 Main St, Springfield, IL 62701",
          timezone: "America/New_York"
        })

      project
    )

if Outreach.list_prospects(project.id) == [] do
  for attrs <- [
        %{
          email: "sam@riveraroofing.com",
          first_name: "Sam",
          last_name: "Rivera",
          company: "Rivera Roofing",
          title: "Owner"
        },
        %{
          email: "dana@northsidesiding.com",
          first_name: "Dana",
          last_name: "Okafor",
          company: "Northside Siding",
          title: "GM"
        }
      ] do
    {:ok, _} = Outreach.create_prospect(Map.put(attrs, :project_id, project.id))
  end
end

if Outreach.list_sequences(project.id) == [] do
  {:ok, sequence} =
    Outreach.create_sequence(%{project_id: project.id, name: "Roofers — intro"})

  {:ok, _} =
    Outreach.create_step(sequence, %{
      "delay_days" => 0,
      "subject" => "Quick question about {{company}}",
      "body" => """
      Hi {{first_name|there}},

      I build software for exterior contractors — scheduling, estimates and
      job tracking in one place, without the spreadsheet sprawl.

      Worth a look for {{company|your crew}}? Two-minute demo here:

      {{link}}

      {{sender_name}}
      """
    })

  {:ok, _} =
    Outreach.create_step(sequence, %{
      "delay_days" => 3,
      "subject" => "Re: {{company}}",
      "body" => """
      Hi {{first_name|there}},

      Following up on the note above — happy to just send a two-minute video
      instead of setting up a call, if that's easier.

      {{link}}

      {{sender_name}}
      """
    })

  IO.puts("Seeded sequence \"#{sequence.name}\" with 2 steps")
end

IO.puts("Seed complete.")
