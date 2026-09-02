defmodule ColdForge.MergeFields do
  @moduledoc """
  Free-form merge values, edited as one `name: value` per line.

  Used in two places — a prospect's extra fields and a campaign's defaults —
  which is why it lives here rather than in either schema. Same editor, same
  parsing, so a field named the same way behaves the same way in both.
  """

  @doc """
  Moves the `"<field>_text"` textarea contents into `"<field>"` as a map.

  Runs *before* `cast/3`: these are map columns, and cast refuses a plain string
  for one — the value never lands, so a later `update_change` has nothing to
  work on.
  """
  def parse(attrs, field) when is_map(attrs) and is_binary(field) do
    case Map.fetch(attrs, field <> "_text") do
      {:ok, text} when is_binary(text) -> Map.put(attrs, field, from_text(text))
      _ -> attrs
    end
  end

  def parse(attrs, _field), do: attrs

  @doc "Parses `name: value` lines into a map, ignoring blanks and junk."
  def from_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      with [name, value] <- String.split(line, ":", parts: 2),
           name when name != "" <- slug(name),
           value when value != "" <- String.trim(value) do
        Map.put(acc, name, value)
      else
        _ -> acc
      end
    end)
  end

  @doc "Renders a map back into the editor's one-per-line form."
  def to_text(fields) when is_map(fields) do
    fields |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)
  end

  def to_text(_), do: ""

  # Merge tags are `{{crew_size}}`, so a field typed as "Crew Size" has to end
  # up in the same shape the CSV importer produces.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
