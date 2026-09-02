defmodule ColdForge.Calling.Scripts do
  @moduledoc """
  The voicemail scripts, rendered for the person being called.

  Kept in the app rather than on a sticky note because the whole point of a
  four-message cadence is that each one differs — reading the same message four
  times is how a callback rate goes to zero. Numbered so a call can record
  which was left and the next one knows where it is.

  Rules baked into the wording: under twenty seconds, the number said twice,
  one reason to call back, relaxed rather than salesy.
  """

  alias ColdForge.Outreach.{Project, Prospect}

  @doc "The four scripts in order, as `{number, when to use it}`."
  def catalogue do
    [
      {1, "First attempt — curiosity, and something specific to them"},
      {2, "After a no-answer — add the hook"},
      {3, "A trigger, like storm work picking up"},
      {4, "The breakup — highest callback rate of the four"}
    ]
  end

  @doc """
  A script rendered for one prospect, or `nil` if the number isn't set on the
  project — a voicemail without a callback number is a wasted call, and a
  placeholder would be worse than an obvious gap.
  """
  def render(number, %Prospect{} = prospect, %Project{} = project) do
    case project.phone do
      nil -> nil
      "" -> nil
      phone -> do_render(number, first_name(prospect), company(prospect), phone)
    end
  end

  defp do_render(1, name, company, phone) do
    """
    Hey #{name}, it's #{sender()}, #{phone}. I work with roofing and siding
    shops on keeping leads from slipping and crews from getting double-booked.
    Had a quick idea for #{company} — give me a ring when you get a sec,
    #{phone} again. Thanks #{name}.
    """
  end

  defp do_render(2, name, _company, phone) do
    """
    Hey #{name}, #{sender()} again, #{phone}. Not trying to bug you — the reason
    I keep reaching out is I've helped a few West Michigan exterior guys get
    same-day quotes out the door and stop losing jobs to slow follow-up. If
    that's worth 15 minutes, I'm at #{phone}. Talk soon.
    """
  end

  defp do_render(3, name, _company, phone) do
    """
    Hey #{name}, it's #{sender()}, #{phone}. With the storm work picking up, the
    shops that catch every lead fast are the ones cashing in — that's exactly
    what I help with. Quick 15 minutes when the dust settles? #{phone}. Thanks.
    """
  end

  defp do_render(4, name, _company, phone) do
    """
    Hey #{name}, #{sender()} — last time I'll land in your voicemail. I'll assume
    leads and scheduling are running tight for you and close out your file. If
    that ever changes, I'm at #{phone}. Wishing you a busy season.
    """
  end

  defp do_render(_, _, _, _), do: nil

  # The scripts are spoken, so they use a first name rather than the project's
  # full from-name.
  defp sender, do: "Kris"

  defp first_name(%Prospect{first_name: name}) when is_binary(name) and name != "", do: name
  defp first_name(_), do: "there"

  defp company(%Prospect{company: company}) when is_binary(company) and company != "", do: company
  defp company(_), do: "your shop"
end
