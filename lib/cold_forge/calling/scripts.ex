defmodule ColdForge.Calling.Scripts do
  @moduledoc """
  The four voicemails, rendered for the person being called.

  Kept in the app rather than on a sticky note because the whole point of a
  four-message cadence is that each one differs — reading the same message four
  times is how a callback rate goes to zero. Numbered so a call can record
  which was left and the next one knows where it is.

  Rules baked into the wording: under twenty seconds, the number said twice,
  one reason to call back, relaxed rather than salesy.

  ## Defaults, and what a project writes over them

  Each has a default here and a project can replace it, keyed "1" to "4" in
  `Project.voicemail_scripts`. A project with nothing there gets four working
  messages without setup, and only the ones actually reworded are stored —
  which matters because a voicemail that isn't landing is obvious within a day
  of dialling, and the fix shouldn't need a deploy.

  Both paths go through `ColdForge.Sending.Renderer`, so these use the same
  merge tags as the emails and the call scripts: `{{first_name|there}}`,
  `{{company}}`, `{{industry|exterior}}`, and `{{callback}}` for the number.

  ## Why number two asks a question

  The pain-point research — 70 points pulled from Capterra, Reddit and G2
  across JobNimbus, AccuLynx, ServiceTitan and Leap — puts reliability first by
  a distance: six points at mean severity 3.8, plus four more under
  mobile/field reliability at 3.8. Ten of seventy, the largest theme in the
  file, and the quotes are specific: an app that kicks you out fifteen times a
  session, sync that fails monthly, one that "works about 70%".

  It asks rather than asserts, and that is deliberate. Every one of those ten
  points is marked unknown for ExteriorPro — there is no uptime record to point
  at — so the script can ask an owner what breaks on his, and must not claim to
  be the thing that fixes it. The previous wording said "I've helped a few West
  Michigan exterior guys", which was a customer result nobody can name.
  """

  alias ColdForge.Outreach.{Project, Prospect}
  alias ColdForge.Sending.Renderer

  @numbers 1..4

  @doc "The four scripts in order, as `{number, when to use it}`."
  def catalogue do
    [
      {1, "First attempt — curiosity, and something specific to them"},
      {2, "After a no-answer — ask what breaks on what they run now"},
      {3, "A trigger, like storm work picking up"},
      {4, "The breakup — highest callback rate of the four"}
    ]
  end

  @doc "The numbers a voicemail can carry."
  def numbers, do: Enum.to_list(@numbers)

  @doc "How one reads on screen."
  def note(number) do
    case Enum.find(catalogue(), fn {n, _} -> n == number end) do
      {_n, note} -> note
      nil -> nil
    end
  end

  @defaults %{
    1 => """
    Hey {{first_name|there}}, it's Kris, {{callback}}. I work with
    {{industry|exterior}} shops around {{city|West Michigan}} on keeping leads from
    slipping and crews from getting double-booked. Had a quick idea for
    {{company}} — give me a ring when you get a sec, {{callback}} again.
    Thanks.
    """,
    # Asks. Does not assert. See the moduledoc for why.
    2 => """
    Hey {{first_name|there}}, Kris again — {{callback}}.

    I didn't give you much of a reason to call back last time, so here it is:
    what does the software you're on now do on a bad day? Does it hold up, or
    is it the thing everybody works around?

    That's the whole question — no pitch on a voicemail. {{callback}}. Thanks.
    """,
    3 => """
    Hey {{first_name|there}}, it's Kris, {{callback}}. With the storm work picking
    up, the shops that catch every lead fast are the ones cashing in — that's
    exactly what I help with. Quick 15 minutes when the dust settles?
    {{callback}}. Thanks.
    """,
    4 => """
    Hey {{first_name|there}}, Kris — last time I'll land in your voicemail. I'll
    assume leads and scheduling are running tight for you and close out your
    file. If that ever changes, I'm at {{callback}}. Wishing you a busy season.
    """
  }

  @doc "The built-in wording for one number, before any project rewrote it."
  def default(number), do: @defaults |> Map.get(number) |> presence()

  @doc "Every default, keyed as the project stores them."
  def defaults, do: Map.new(@defaults, fn {n, text} -> {to_string(n), String.trim(text)} end)

  @doc """
  A script rendered for one prospect, or `nil` if the number isn't set on the
  project — a voicemail without a callback number is a wasted call, and a
  placeholder would be worse than an obvious gap.

  The project's own wording wins over the default.
  """
  def render(number, %Prospect{} = prospect, %Project{} = project) do
    case presence(project.phone) do
      nil ->
        nil

      _phone ->
        case template(number, project) do
          nil -> nil
          text -> Renderer.preview(text, prospect, project)
        end
    end
  end

  def render(_number, _prospect, _project), do: nil

  @doc """
  What a project would send for one number, before merge tags are applied —
  its own wording if it has any, otherwise the default.
  """
  def template(number, %Project{} = project) do
    case project.voicemail_scripts do
      scripts when is_map(scripts) ->
        scripts |> Map.get(to_string(number)) |> presence() || default(number)

      _ ->
        default(number)
    end
  end

  @doc "Whether this project has reworded one, rather than taking the default."
  def rewritten?(number, %Project{voicemail_scripts: scripts}) when is_map(scripts),
    do: scripts |> Map.get(to_string(number)) |> presence() != nil

  def rewritten?(_number, _project), do: false

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
