defmodule ColdForge.Sourcing.Discovery.LicenseCsv do
  @moduledoc """
  State contractor licence registries, as downloaded CSV.

  These are the complete roster for the trades: a licensed roofer is in the
  state's file whether or not anyone has added them to OpenStreetMap. That
  makes them the opposite trade-off to Overpass — full coverage, but almost
  never a website, so rows land as `needs_website`.

  There is no common format. Every state names its columns differently, some
  publish one row per licence and others one per trade endorsement, and a few
  only offer a lookup form with no download at all. So rather than pretending
  there is a single parser, this takes the mapping as data: say which of their
  columns is the business name, which is the city, and which words in their
  trade column mean which of our segments.

  A mapping for one state is a few lines and is worth keeping in config beside
  the file it describes.
  """

  NimbleCSV.define(ColdForge.Sourcing.Discovery.LicenseCsv.Parser, separator: ",", escape: "\"")

  alias ColdForge.Sourcing.Discovery.LicenseCsv.Parser
  alias ColdForge.Sourcing.Org

  @type mapping :: %{
          required(:source_name) => String.t(),
          required(:columns) => %{atom() => String.t()},
          optional(:segment_column) => String.t(),
          optional(:segment_rules) => [{String.t(), String.t()}],
          optional(:default_segment) => String.t(),
          optional(:region) => String.t()
        }

  @doc """
  Parses a registry export using `mapping`.

  `:columns` maps our fields to theirs. `:segment_rules` is an ordered list of
  `{substring, segment}` matched case-insensitively against `:segment_column`;
  the first hit wins, and a row matching none is dropped unless
  `:default_segment` is set.

      %{
        source_name: "mi_lara_builders",
        region: "MI",
        columns: %{name: "BUSINESS NAME", city: "CITY", license: "LICENSE NUMBER"},
        segment_column: "SPECIALTY",
        segment_rules: [{"roof", "roofing"}, {"siding", "siding"}]
      }
  """
  @spec parse(String.t(), mapping()) :: {:ok, [map()]} | {:error, term()}
  def parse(csv, mapping) when is_binary(csv) and is_map(mapping) do
    with :ok <- validate_mapping(mapping),
         {:ok, [header | rows]} <- read(csv),
         index = index_of(header),
         :ok <- require_mapped_columns(index, mapping) do
      parsed =
        rows
        |> Enum.map(&row_to_attrs(&1, index, mapping))
        |> Enum.reject(&is_nil/1)
        |> dedupe()

      {:ok, parsed}
    end
  end

  defp validate_mapping(%{source_name: _, columns: %{name: _}}), do: :ok
  defp validate_mapping(_), do: {:error, :mapping_needs_source_name_and_name_column}

  defp read(csv) do
    case Parser.parse_string(csv, skip_headers: false) do
      [] -> {:error, :empty}
      rows -> {:ok, rows}
    end
  rescue
    error -> {:error, {:unparsable_csv, Exception.message(error)}}
  end

  defp index_of(header) do
    header
    |> Enum.with_index()
    |> Map.new(fn {name, i} -> {normalize_header(name), i} end)
  end

  # Registry headers arrive with stray spaces, BOMs and inconsistent case.
  defp normalize_header(name) do
    name
    |> to_string()
    |> String.replace("﻿", "")
    |> String.trim()
    |> String.upcase()
  end

  defp require_mapped_columns(index, mapping) do
    wanted =
      mapping.columns
      |> Map.values()
      |> then(fn cols ->
        case Map.get(mapping, :segment_column) do
          nil -> cols
          segment_col -> [segment_col | cols]
        end
      end)
      |> Enum.map(&normalize_header/1)

    case Enum.reject(wanted, &Map.has_key?(index, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_columns, missing}}
    end
  end

  defp row_to_attrs(row, index, mapping) do
    get = fn field ->
      case Map.get(mapping.columns, field) do
        nil -> nil
        column -> at(row, Map.get(index, normalize_header(column)))
      end
    end

    with name when is_binary(name) <- get.(:name),
         segment when is_binary(segment) <- segment_for(row, index, mapping) do
      %{
        name: name,
        segment: segment,
        website: Org.normalize_website(get.(:website)),
        phone: get.(:phone),
        street: get.(:street),
        city: get.(:city),
        region: get.(:region) || Map.get(mapping, :region),
        postal_code: get.(:postal_code),
        country: "US",
        provider: "license_csv",
        source_ref: source_ref(mapping, get),
        source_url: Map.get(mapping, :source_url),
        raw: %{"registry" => mapping.source_name, "license" => get.(:license)}
      }
    else
      _ -> nil
    end
  end

  # A licence number makes the row stable across re-downloads. Without one the
  # best available key is the registry plus the name and city, which is good
  # enough to stop a re-import duplicating everything.
  defp source_ref(mapping, get) do
    case get.(:license) do
      nil ->
        "#{mapping.source_name}:#{slug(get.(:name))}:#{slug(get.(:city))}"

      license ->
        "#{mapping.source_name}:#{license}"
    end
  end

  defp segment_for(row, index, mapping) do
    case Map.get(mapping, :segment_column) do
      nil ->
        Map.get(mapping, :default_segment)

      column ->
        value =
          row |> at(Map.get(index, normalize_header(column))) |> to_string() |> String.downcase()

        rules = Map.get(mapping, :segment_rules, [])

        Enum.find_value(rules, Map.get(mapping, :default_segment), fn {needle, segment} ->
          if String.contains?(value, String.downcase(needle)), do: segment
        end)
    end
  end

  # Several states publish one row per trade endorsement, so the same company
  # appears three times. Same licence, same segment, one prospect.
  defp dedupe(rows) do
    rows
    |> Enum.uniq_by(&{&1.source_ref, &1.segment})
  end

  defp slug(nil), do: ""

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp at(_row, nil), do: nil

  defp at(row, index) do
    case row |> Enum.at(index) do
      nil -> nil
      value -> presence(value)
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
