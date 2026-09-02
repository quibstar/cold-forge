# Dev seed: an operator account, the ExteriorPro project, and the real West
# Michigan outreach campaign — so a fresh database comes up as something you
# can actually look at rather than an empty shell.
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: every section checks before it writes, so running it against an
# existing database changes nothing.

alias ColdForge.{Accounts, Outreach, Repo, Survey}

email = "quibstar@gmail.com"

unless Accounts.get_user_by_email(email) do
  {:ok, user} = Accounts.register_user(%{email: email})

  # Confirmed and given a password so a fresh database is usable immediately.
  # This runs only when you invoke seeds by hand, and only ever against a
  # database you just created — but it is still a known password, so never
  # point this at anything reachable from outside your machine.
  user
  |> Ecto.Changeset.change(
    confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
    hashed_password: Bcrypt.hash_pwd_salt("devpassword123!")
  )
  |> Repo.update!()

  IO.puts("Created operator #{email} — log in at /users/log-in with devpassword123!")
end

project =
  Outreach.get_project_by_slug("exteriorpro") ||
    (
      {:ok, project} =
        Outreach.create_project(%{
          "name" => "ExteriorPro",
          "slug" => "exteriorpro",
          # A person writes, the company signs. Owner-operators answer a person
          # rather than a brand, so the from-name stays personal while the
          # sign-off carries the company.
          "from_name" => "Kris Utter",
          "from_email" => "kris@exteriorpro.io",
          "landing_url" => "https://exteriorpro.io/demo",
          "signature" =>
            "Kris Utter\nExteriorPro — a product of Affordable Startup LLC\nexteriorpro.io",
          # Deliberately not a plausible address. CAN-SPAM requires a real one
          # in commercial mail, so a convincing placeholder would ship as a lie
          # nobody noticed. Loud beats plausible.
          "postal_address" =>
            "Affordable Startup LLC — REPLACE WITH YOUR REGISTERED POSTAL ADDRESS BEFORE SENDING",
          "merge_defaults_text" => "industry: exterior contractors\nproduct: ExteriorPro",
          "timezone" => "America/New_York"
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
          title: "Owner",
          industry: "roofing"
        },
        %{
          email: "dana@northsidesiding.com",
          first_name: "Dana",
          last_name: "Okafor",
          company: "Northside Siding",
          title: "GM",
          industry: "siding"
        }
      ] do
    {:ok, _} = Outreach.create_prospect(Map.put(attrs, :project_id, project.id))
  end
end

# The survey is the opener: asking a stranger for fifteen minutes is a big first
# ask, and asking one question they answer in a single click is a small one.
# Every option maps to a feature, so a click tells you what the follow-up says.
survey =
  Enum.find(Survey.list_surveys(project.id), &(&1.name == "What eats the most time")) ||
    (
      {:ok, survey} =
        Survey.create_survey(%{
          "project_id" => project.id,
          "name" => "What eats the most time",
          "intro" => "Thanks — that's genuinely useful. One more if you've got a second.",
          "thank_you" => "That helps a lot. I'll send over what everyone else said.",
          "questions" => %{
            "0" => %{
              "position" => "1",
              "kind" => "choice",
              "prompt" => "What eats the most time in a week?",
              "options" =>
                "Chasing leads that went cold\nTwo crews at the same house\nGetting quotes out\nChasing payments\nSomething else"
            },
            "1" => %{
              "position" => "2",
              "kind" => "text",
              "prompt" => "What would have to change for that to stop being a problem?"
            }
          },
          "questions_order" => ["0", "1"]
        })

      survey
    )

if Outreach.list_campaigns(project.id) == [] do
  {:ok, campaign} =
    Outreach.create_campaign(%{
      "project_id" => project.id,
      "name" => "West Michigan exteriors — survey opener",
      # Not the 8–17 default: an owner-operator is on a roof at ten in the
      # morning. Late afternoon is when they are back at a desk, or a phone.
      "send_window_start" => 16,
      "send_window_end" => 19,
      "send_days" => [1, 2, 3, 4],
      # Deliberately slow. A domain with no sending history that suddenly emits
      # hundreds a day is how a sending domain gets blocked, usually for good.
      "daily_cap" => 25
    })

  {:ok, _} =
    Outreach.create_step(campaign, %{
      "subject" => "quick question, {{company}}",
      "survey_id" => survey.id,
      "body" => """
      Hi {{first_name|there}},

      I'm with Affordable Startup LLC — we make ExteriorPro, software built for
      {{industry}} rather than bent to fit them.

      One question, takes five seconds:

      {{survey}}

      That's it. Happy to share what everyone else says.
      """
    })

  {:ok, _} =
    Outreach.create_step(campaign, %{
      "delay_days" => 3,
      "subject" => "Re: quick question, {{company}}",
      "body" => """
      Hi {{first_name|there}},

      No worries if that wasn't the moment.

      The thing we hear most from shops your size: a lead comes in, nobody
      catches it fast enough, and it's gone. Same story with two crews landing
      at the same house.

      That's the gap ExteriorPro closes — every lead in one place,
      good/better/best quotes built on the driveway, one calendar across crews.

      Worth 15 minutes? {{link}}
      """
    })

  # The breakup reliably outperforms everything before it: it is the one that
  # asks for nothing.
  {:ok, _} =
    Outreach.create_step(campaign, %{
      "delay_days" => 5,
      "subject" => "closing your file, {{company}}",
      "body" => """
      Hi {{first_name|there}},

      Last one from me — I'll assume leads and scheduling are running tight at
      {{company}} and close out your file.

      If that ever changes: {{link}}

      Busy season to you.
      """
    })

  IO.puts(~s(Seeded campaign "#{campaign.name}" — 3 emails, draft, sends 16:00-19:00))
end

IO.puts("Seed complete.")
