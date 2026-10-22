defmodule ColdForge.Outreach.CallScripts do
  @moduledoc """
  Reading a project's call scripts for one prospect.

  The rows live in `ColdForge.Outreach.CallScript` and are edited on their own
  screen; this is the part the call page uses — which tabs to draw, and what
  each says once the prospect's details are in it.

  ## Templates, not copies

  The scripts arrived from ExteriorPro as text on every prospect: a sheet per
  script, a row per company, the company and the town pasted in. 112 prospects
  came to 504KB of prose, where `objections` had four distinct values across
  the whole list. Changing a line meant changing it 112 times.

  So a script is written once and `ColdForge.Sending.Renderer` reads the
  prospect's details in at the moment somebody opens the page, using the same
  merge tags as the emails — `{{company}}`, `{{city}}`,
  `{{industry|exterior}}`, `{{callback}}`. Nothing is stored on a prospect.
  """

  alias ColdForge.Outreach
  alias ColdForge.Outreach.CallScript
  alias ColdForge.Sending.Renderer

  @doc """
  Every script this project has, as `{script, rendered}`, in reading order.

  One query, because the call page draws a tab per script and then shows one
  of them — asking per tab would be a query per tab.
  """
  def for_prospect(prospect, project) do
    project.id
    |> Outreach.list_call_scripts("script")
    |> Enum.map(&{&1, render(&1, prospect, project)})
  end

  @doc "The voicemails, as `{script, rendered}`, in cadence order."
  def voicemails_for_prospect(prospect, project) do
    project.id
    |> Outreach.list_call_scripts("voicemail")
    |> Enum.map(&{&1, render(&1, prospect, project)})
  end

  @doc "One script rendered for one prospect."
  def render(%CallScript{body: body}, prospect, project) when is_binary(body),
    do: Renderer.preview(body, prospect, project)

  def render(_script, _prospect, _project), do: nil

  @doc """
  Which script the page opens on, given the ones it has.

  The first, because they are in the order somebody put them in and the first
  is the one they reach for.
  """
  def default_tab([{script, _rendered} | _]), do: script.id
  def default_tab(_), do: nil

  @doc "Whether this project has written any script at all."
  def any?(project), do: Outreach.list_call_scripts(project.id, "script") != []
end
