defmodule ColdForge.OutreachFixtures do
  @moduledoc "Fixtures for projects, prospects, sequences and steps."

  alias ColdForge.Outreach

  def project_fixture(attrs \\ %{}) do
    {:ok, project} =
      attrs
      |> Enum.into(%{
        name: "ExteriorPro #{System.unique_integer([:positive])}",
        from_name: "Kris Utter",
        from_email: "kris@exteriorpro.io",
        landing_url: "https://exteriorpro.io/demo",
        postal_address: "123 Main St, Springfield, IL",
        timezone: "America/New_York"
      })
      |> Outreach.create_project()

    project
  end

  def prospect_fixture(project, attrs \\ %{}) do
    {:ok, prospect} =
      attrs
      |> Enum.into(%{
        project_id: project.id,
        email: "prospect#{System.unique_integer([:positive])}@example.com",
        first_name: "Sam",
        last_name: "Rivera",
        company: "Rivera Roofing"
      })
      |> Outreach.create_prospect()

    prospect
  end

  def sequence_fixture(project, attrs \\ %{}) do
    {:ok, sequence} =
      attrs
      |> Enum.into(%{project_id: project.id, name: "Intro"})
      |> Outreach.create_sequence()

    sequence
  end

  def step_fixture(sequence, attrs \\ %{}) do
    {:ok, step} =
      Outreach.create_step(
        sequence,
        Enum.into(attrs, %{
          "subject" => "Quick question about {{company}}",
          "body" => "Hi {{first_name|there}},\n\nDemo: {{link}}\n\n{{sender_name}}",
          "delay_days" => 0
        })
      )

    step
  end
end
