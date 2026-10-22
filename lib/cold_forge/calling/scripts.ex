defmodule ColdForge.Calling.Scripts do
  @moduledoc """
  The voicemail cadence: which message to leave next, and what it says.

  Each is a `ColdForge.Outreach.CallScript` of kind `voicemail`, numbered by
  `position`, which is also what a call records when one is left. Edited on the
  scripts screen like everything else — a voicemail that isn't landing is
  obvious within a day of dialling, and fixing it shouldn't need a deploy.

  The point of a cadence is that each one differs: reading the same message
  four times is how a callback rate goes to zero. The rules the wording keeps
  are in `defaults/0` — under twenty seconds, the number said twice, one reason
  to call back, relaxed rather than salesy.
  """

  alias ColdForge.Outreach
  alias ColdForge.Outreach.CallScripts

  @doc """
  The message at one position, rendered for this prospect, or `nil`.

  `nil` when the project has no callback number: a voicemail that says "ring me
  back on —" is a wasted call, and a placeholder would be worse than an obvious
  gap.
  """
  def render(nil, _prospect, _project), do: nil

  def render(position, prospect, project) do
    case presence(project.phone) do
      nil ->
        nil

      _phone ->
        project.id
        |> Outreach.list_call_scripts("voicemail")
        |> Enum.find(&(&1.position == position))
        |> case do
          nil -> nil
          script -> CallScripts.render(script, prospect, project)
        end
    end
  end

  @doc "What the message at one position is called, for the screen."
  def note(position, project) do
    project.id
    |> Outreach.list_call_scripts("voicemail")
    |> Enum.find(&(&1.position == position))
    |> case do
      nil -> nil
      script -> script.name
    end
  end

  @doc """
  The wording a new project starts with.

  Seeded as rows rather than held as a fallback, so the first thing somebody
  does with them is edit them rather than discover they are in the source.
  Number two asks rather than asserts: the pain-point research puts reliability
  first — six points at mean severity 3.8, plus four more under mobile/field
  reliability, ten of seventy — and every one of those ten is marked unknown
  for ExteriorPro, so the script may ask an owner what breaks on his and must
  not claim to be the fix.
  """
  def defaults do
    [
      %{
        position: 1,
        name: "First attempt — curiosity, and something specific to them",
        body: """
        Hey {{first_name|there}}, it's Kris, {{callback}}. I work with
        {{industry|exterior}} shops around {{city|West Michigan}} on keeping leads
        from slipping and crews from getting double-booked. Had a quick idea for
        {{company}} — give me a ring when you get a sec, {{callback}} again.
        Thanks.
        """
      },
      %{
        position: 2,
        name: "After a no-answer — ask what breaks on what they run now",
        body: """
        Hey {{first_name|there}}, Kris again — {{callback}}.

        I didn't give you much of a reason to call back last time, so here it is:
        what does the software you're on now do on a bad day? Does it hold up, or
        is it the thing everybody works around?

        That's the whole question — no pitch on a voicemail. {{callback}}. Thanks.
        """
      },
      %{
        position: 3,
        name: "A trigger, like storm work picking up",
        body: """
        Hey {{first_name|there}}, it's Kris, {{callback}}. With the storm work
        picking up, the shops that catch every lead fast are the ones cashing in —
        that's exactly what I help with. Quick 15 minutes when the dust settles?
        {{callback}}. Thanks.
        """
      },
      %{
        position: 4,
        name: "The breakup — highest callback rate of the four",
        body: """
        Hey {{first_name|there}}, Kris — last time I'll land in your voicemail.
        I'll assume leads and scheduling are running tight for you and close out
        your file. If that ever changes, I'm at {{callback}} — that's
        {{callback}}. Wishing you a busy season.
        """
      }
    ]
    |> Enum.map(&%{&1 | body: String.trim(&1.body)})
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
