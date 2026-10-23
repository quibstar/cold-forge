defmodule ColdForge.Calling.Scripts do
  @moduledoc """
  The voicemails a project can start from: one script called "Voicemails",
  read as a tab on the call page like any other.

  They were a list of their own once, shown under every tab with a "due next"
  badge. Nothing recorded which one was left, so the badge never moved — and
  they are words to read like everything else, so they are a script now.

  The point of four is that each one differs: reading the same message four
  times is how a callback rate goes to zero. The rules the wording keeps —
  under twenty seconds, the number said twice, one reason to call back,
  relaxed rather than salesy — are in the text below.
  """

  @name "Voicemails"

  @doc "What the starter script is called, so the Scripts page can tell it's there."
  def voicemails_name, do: @name

  @doc """
  The starter script, ready for `ColdForge.Outreach.create_call_script/1`.

  Number two asks rather than asserts: the pain-point research puts reliability
  first — six points at mean severity 3.8, plus four more under mobile/field
  reliability, ten of seventy — and every one of those ten is marked unknown
  for ExteriorPro, so the script may ask an owner what breaks on theirs and
  must not claim to be the fix.
  """
  def voicemails do
    body =
      sections()
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{title, text}, n} ->
        "VOICEMAIL #{n} — #{String.upcase(title)}\n#{String.trim(text)}"
      end)

    %{name: @name, body: body}
  end

  defp sections do
    [
      {"First attempt — curiosity, and something specific to them",
       """
       Hey {{first_name|there}}, it's Kris, {{callback}}. We work with
       {{industry|exterior}} shops around {{city|West Michigan}} on keeping leads
       from slipping and crews from getting double-booked. Had a quick idea for
       {{company}} — give me a ring when you get a sec, {{callback}} again.
       Thanks.
       """},
      {"After a no-answer — ask what breaks on what they run now",
       """
       Hey {{first_name|there}}, Kris again — {{callback}}.

       I didn't give you much of a reason to call back last time, so here it is:
       what does the software you're on now do on a bad day? Does it hold up, or
       is it the thing everybody works around?

       That's the whole question — no pitch on a voicemail. {{callback}}. Thanks.
       """},
      {"A trigger, like storm work picking up",
       """
       Hey {{first_name|there}}, it's Kris, {{callback}}. With the storm work
       picking up, the shops that catch every lead fast are the ones cashing in —
       that's exactly what we help with. Quick 15 minutes when the dust settles?
       {{callback}}. Thanks.
       """},
      {"The breakup — highest callback rate of the four",
       """
       Hey {{first_name|there}}, Kris — last time I'll land in your voicemail.
       I'll assume leads and scheduling are running tight for you and close out
       your file. If that ever changes, I'm at {{callback}} — that's
       {{callback}}. Wishing you a busy season.
       """}
    ]
  end
end
