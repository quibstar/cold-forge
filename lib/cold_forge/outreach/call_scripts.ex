defmodule ColdForge.Outreach.CallScripts do
  @moduledoc """
  The call scripts: written once per project, read with one prospect's details
  in them.

  Not to be confused with `ColdForge.Calling.Scripts`, which is the numbered
  voicemail cadence — four messages that know which have already been left.
  These are the scripts for a live call, and there are three of them because
  there are three ways to open the same conversation.

  ## Templates, not copies

  They arrived from ExteriorPro as six text fields on every prospect, which is
  how they had been generated: a sheet per script, a row per company, the
  company and the town pasted in. That meant 112 copies of four paragraphs —
  and `objections` had four distinct values across the whole list while
  `problem_question` had nine. Changing a line meant changing it 112 times, or
  regenerating the sheet and re-importing.

  So a script lives on the project, written with the same merge tags the emails
  use — `{{company}}`, `{{city}}`, `{{industry|exterior}}` — and
  `ColdForge.Sending.Renderer` reads the prospect's details into it at the
  moment somebody opens the call page. One edit, 112 prospects.

  A prospect's own `custom_fields` still wins where it has one, because a shop
  occasionally earns its own wording. Nothing fills those by default, and the
  prospect form is where one gets written.
  """

  # Three ways to open the same call, in the order the tabs show them, each with
  # the parts it is read in. The grouping is ExteriorPro's and it is the point:
  # the choice between them is made mid-dial, so they are tabs on one panel
  # rather than three panels to scroll between.
  @tabs [
    {"original", "Script 1",
     [
       {"opener", "Opener"},
       {"problem_question", "Problem awareness"},
       {"objections", "If they object"},
       {"voicemail", "Voicemail"}
     ]},
    {"direct", "Script 2", [{"script_direct", "Straight pitch"}]},
    {"nepq", "NEPQ Awareness", [{"script_nepq", "NEPQ awareness"}]}
  ]

  @keys Enum.flat_map(@tabs, fn {_key, _label, parts} -> Enum.map(parts, &elem(&1, 0)) end)

  @doc "Every tab, as `{key, label, parts}`, whether or not anybody has one."
  def tabs, do: @tabs

  @doc "The `custom_fields` keys these scripts occupy."
  def keys, do: @keys

  @doc "Whether a `custom_fields` key is one of the scripts."
  def script_key?(key), do: to_string(key) in @keys

  @doc "How one key reads on screen."
  def label(key) do
    key = to_string(key)

    Enum.find_value(@tabs, key, fn {_tab, _tab_label, parts} ->
      Enum.find_value(parts, fn {part, label} -> if part == key, do: label end)
    end)
  end

  @doc """
  What this prospect would read under one key, template rendered, or `nil`.

  The prospect's own wording first, then the project's template with their
  details read into it. A blank is a blank either way: a tab with nothing
  behind it is one you click once, find empty, and never trust again.
  """
  def body(prospect, project, key) do
    case Map.get(fields_of(prospect), to_string(key)) do
      own when is_binary(own) ->
        if filled?(own), do: own, else: template_body(prospect, project, key)

      _ ->
        template_body(prospect, project, key)
    end
  end

  defp template_body(prospect, project, key) do
    case Map.get(templates_of(project), to_string(key)) do
      template when is_binary(template) ->
        if filled?(template), do: render(template, prospect, project), else: nil

      _ ->
        nil
    end
  end

  # The same renderer and the same tag syntax the emails use, so `{{company}}`
  # means one thing across the app and a fallback (`{{industry|exterior}}`)
  # degrades a thin row into a sentence somebody can still read aloud.
  defp render(template, prospect, project) do
    ColdForge.Sending.Renderer.preview(template, prospect, project)
  end

  @doc """
  The tabs that have something to read, as `{key, label}`.

  A tab whose script neither the prospect nor the project has is not drawn at
  all.
  """
  def available(prospect, project) do
    for {key, label, parts} <- @tabs,
        Enum.any?(parts, fn {part, _} -> body(prospect, project, part) end),
        do: {key, label}
  end

  @doc "Whether there is any script at all to read from."
  def any?(prospect, project), do: available(prospect, project) != []

  @doc """
  Which tab to open on — whichever there is a script for.

  A project with only one of the three written shouldn't land you on a blank
  tab.
  """
  def default_tab(prospect, project) do
    case available(prospect, project) do
      [{key, _label} | _] -> key
      [] -> "original"
    end
  end

  @doc "The filled parts of one tab, as `{label, body}`, in reading order."
  def parts(prospect, project, tab_key) do
    case Enum.find(@tabs, fn {key, _label, _parts} -> key == tab_key end) do
      nil ->
        []

      {_key, _label, parts} ->
        for {part, label} <- parts,
            rendered = body(prospect, project, part),
            do: {label, rendered}
    end
  end

  @doc """
  Whether this prospect overrides a script the project already has.

  Worth saying on the form: an override is invisible from the project's side,
  and somebody editing the template there would otherwise wonder why one shop
  never changes.
  """
  def overridden(prospect, project) do
    own = scripts(fields_of(prospect))
    templates = templates_of(project)

    for {key, value} <- own, filled?(value), filled?(Map.get(templates, key)), do: key
  end

  defp templates_of(%{call_scripts: scripts}), do: stringify(scripts)
  defp templates_of(_), do: %{}

  @doc "Just the scripts out of a `custom_fields` map."
  def scripts(fields) when is_map(fields), do: Map.take(fields, @keys)
  def scripts(_), do: %{}

  @doc """
  Everything in a `custom_fields` map that isn't a script — what belongs in the
  one-per-line editor.
  """
  def extras(fields) when is_map(fields), do: Map.drop(fields, @keys)
  def extras(_), do: %{}

  @doc """
  Works out the `custom_fields` a save should land, given what the form sent.

  Runs after `ColdForge.MergeFields.parse/2`, which has by then turned the
  one-per-line textarea into `"custom_fields"` — the extras, and only the
  extras, because the editor no longer shows the scripts. Two cases, and both
  are about a form that was shown half the map:

    * the script textareas were submitted — their contents win, and a script
      left blank is a script deleted, which is what blanking a textarea means;

    * they weren't — this form didn't show them, so whatever scripts the
      prospect already has survive rather than being dropped by a save that
      only touched the extras.

  Attrs with atom keys (the CSV importer, the migration task, seeds) set
  `custom_fields` wholesale and are passed through untouched.
  """
  def put_custom_fields(prospect, attrs) when is_map(attrs) do
    case Map.fetch(attrs, "call_scripts") do
      {:ok, submitted} when is_map(submitted) ->
        Map.put(attrs, "custom_fields", Map.merge(extras_from(prospect, attrs), clean(submitted)))

      _ ->
        case Map.fetch(attrs, "custom_fields") do
          {:ok, fields} when is_map(fields) ->
            Map.put(attrs, "custom_fields", Map.merge(scripts(fields_of(prospect)), fields))

          _ ->
            attrs
        end
    end
  end

  def put_custom_fields(_prospect, attrs), do: attrs

  # The extras the form sent, or the ones already saved when it didn't send any.
  defp extras_from(prospect, attrs) do
    case Map.fetch(attrs, "custom_fields") do
      {:ok, fields} when is_map(fields) -> extras(fields)
      _ -> extras(fields_of(prospect))
    end
  end

  defp clean(submitted) do
    for {key, value} <- submitted,
        script_key?(key),
        filled?(value),
        into: %{},
        do: {to_string(key), String.trim(value)}
  end

  # Either a prospect or a bare `custom_fields` map, so callers don't have to
  # care which they are holding.
  defp fields_of(%{custom_fields: fields}), do: stringify(fields)
  defp fields_of(fields), do: stringify(fields)

  defp stringify(fields) when is_map(fields) and not is_struct(fields),
    do: Map.new(fields, fn {k, v} -> {to_string(k), v} end)

  defp stringify(_), do: %{}

  defp filled?(value), do: is_binary(value) and String.trim(value) != ""
end
