defmodule ColdForge.Outreach.CallScripts do
  @moduledoc """
  The scripts written for one particular business, read from a prospect's
  `custom_fields`.

  Not to be confused with `ColdForge.Calling.Scripts`, which is the opposite
  thing: four generic voicemails, numbered, the same for everybody, rendered
  with merge values. These are hand-written per company — the opener names the
  shop, the voicemail names the shop — and they came across from ExteriorPro's
  own call list, where they were six columns on the prospect.

  ## Why `custom_fields` and not six columns

  They are prose a person wrote for one company, which is exactly what that map
  is for, and living there makes them reachable as merge tags (`{{opener}}`)
  without the renderer learning anything new. Six more text columns would buy
  nothing but a migration.

  The one thing that had to change is the editor. `custom_fields` is edited as
  one `name: value` per line, which cannot represent a 2,000-character script:
  rendering one into that textarea and saving it back would drop every line
  after the first and turn any line with a colon in it into a field of its own.
  So the script keys are split out of that textarea and get their own, and this
  module is what both halves agree on. `put_custom_fields/2` is the part that
  keeps a save from losing the half it wasn't shown.
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
  The tabs this prospect actually has something on, as `{key, label}`.

  A tab whose script they haven't got is not drawn at all: an empty tab is a
  thing you click once, find nothing in, and never trust again.
  """
  def available(prospect) do
    fields = fields_of(prospect)

    for {key, label, parts} <- @tabs,
        Enum.any?(parts, fn {part, _} -> filled?(Map.get(fields, part)) end),
        do: {key, label}
  end

  @doc "Whether there is any script at all to read from."
  def any?(prospect), do: available(prospect) != []

  @doc """
  Which tab to open on — whichever this prospect actually has.

  A list imported with only one of the three shouldn't land you on a blank tab.
  """
  def default_tab(prospect) do
    case available(prospect) do
      [{key, _label} | _] -> key
      [] -> "original"
    end
  end

  @doc "The filled parts of one tab, as `{label, body}`, in reading order."
  def parts(prospect, tab_key) do
    fields = fields_of(prospect)

    case Enum.find(@tabs, fn {key, _label, _parts} -> key == tab_key end) do
      nil ->
        []

      {_key, _label, parts} ->
        for {part, label} <- parts, filled?(Map.get(fields, part)), do: {label, fields[part]}
    end
  end

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
