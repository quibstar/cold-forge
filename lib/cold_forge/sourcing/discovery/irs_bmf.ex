defmodule ColdForge.Sourcing.Discovery.IrsBmf do
  @moduledoc """
  The IRS Exempt Organizations Business Master File.

  Free, public domain, and as close to complete as this gets: roughly 1.9
  million registered nonprofits, published as CSV by state and region, sorted
  by EIN. For shelters and rescues it is the only source that is not a sample —
  NTEE code **D20** is Animal Protection & Welfare, and essentially every
  legitimate shelter and rescue in the country has one.

  **It carries no website and no email.** Name, EIN and a mailing address, and
  that is all. So a row from here lands as `needs_website` and has to have a
  site resolved before the crawler has anything to fetch. That resolution step
  is the real work this source creates, and it is worth it: the alternative is
  a sample of 35 Michigan shelters from OpenStreetMap when the state has
  several hundred.

  Download: <https://www.irs.gov/charities-non-profits/exempt-organizations-business-master-file-extract-eo-bmf>
  """

  NimbleCSV.define(ColdForge.Sourcing.Discovery.IrsBmf.Parser, separator: ",", escape: "\"")

  alias ColdForge.Sourcing.Discovery.IrsBmf.Parser

  # Animal Protection & Welfare. D is the animal-related major group; D20 is
  # the shelters-and-rescues code specifically. Anything broader drags in
  # wildlife funds, zoos and bird sanctuaries, which are not listing pets.
  @default_ntee ["D20"]

  @doc "NTEE codes treated as a shelter or rescue by default."
  def default_ntee, do: @default_ntee

  @doc """
  Parses a BMF extract into rows for `Sourcing.Org`.

  Options:

    * `:ntee` — code prefixes to keep (default `["D20"]`)
    * `:states` — two-letter codes to keep, e.g. `["MI"]`. Omit for all.

  The file's columns vary slightly between releases, so the header row is read
  rather than assumed; a file missing `NAME` or `EIN` is an error rather than a
  silent empty result.
  """
  @spec parse(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def parse(csv, opts \\ []) when is_binary(csv) do
    ntee = Keyword.get(opts, :ntee, @default_ntee)
    states = Keyword.get(opts, :states)

    with {:ok, [header | rows]} <- read(csv),
         index = index_of(header),
         :ok <- require_columns(index) do
      parsed =
        rows
        |> Enum.map(&row_to_attrs(&1, index))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&keep?(&1, ntee, states))

      {:ok, parsed}
    end
  end

  defp read(csv) do
    {:ok, csv |> Parser.parse_string(skip_headers: false)}
  rescue
    error -> {:error, {:unparsable_csv, Exception.message(error)}}
  end

  defp index_of(header) do
    header
    |> Enum.with_index()
    |> Map.new(fn {name, i} -> {name |> String.trim() |> String.upcase(), i} end)
  end

  defp require_columns(index) do
    case Enum.reject(["EIN", "NAME"], &Map.has_key?(index, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_columns, missing}}
    end
  end

  defp row_to_attrs(row, index) do
    get = fn column -> at(row, Map.get(index, column)) end

    with ein when is_binary(ein) <- get.("EIN"),
         name when is_binary(name) <- get.("NAME") do
      ntee = get.("NTEE_CD")

      %{
        name: titleize(name),
        segment: segment_for(name),
        website: nil,
        phone: nil,
        street: get.("STREET") |> titleize(),
        city: get.("CITY") |> titleize(),
        region: get.("STATE"),
        postal_code: get.("ZIP") |> short_zip(),
        country: "US",
        source: "irs_bmf",
        source_ref: ein,
        source_url: "https://apps.irs.gov/app/eos/",
        raw: %{"ntee_cd" => ntee, "subsection" => get.("SUBSECTION")}
      }
    else
      _ -> nil
    end
  end

  defp keep?(attrs, ntee_prefixes, states) do
    code = get_in(attrs, [:raw, "ntee_cd"]) || ""
    ntee_ok = Enum.any?(ntee_prefixes, &String.starts_with?(code, &1))
    state_ok = is_nil(states) or attrs.region in states
    ntee_ok and state_ok
  end

  # The BMF shouts: "HUMANE SOCIETY OF WEST MICHIGAN". Sent as-is into a merge
  # tag it reads like a summons, so it is cased here rather than in the email.
  defp titleize(nil), do: nil

  defp titleize(text) do
    case String.trim(text) do
      "" ->
        nil

      trimmed ->
        if trimmed == String.upcase(trimmed) do
          trimmed
          |> String.split(~r/\s+/)
          |> Enum.map_join(" ", &capitalize_word/1)
        else
          trimmed
        end
    end
  end

  # Keep initialisms that are genuinely initialisms, lowercase the joining
  # words, capitalise everything else.
  @keep_upper ~w(SPCA ASPCA USA US II III IV NW NE SW SE)
  @keep_lower ~w(of the and for a an at in on to)

  defp capitalize_word(word) do
    cond do
      word in @keep_upper -> word
      String.downcase(word) in @keep_lower -> String.downcase(word)
      true -> String.capitalize(word)
    end
  end

  # ZIP+4 is noise on an envelope we are not addressing.
  defp short_zip(nil), do: nil
  defp short_zip(zip), do: zip |> String.trim() |> String.slice(0, 5) |> presence()

  defp segment_for(name) do
    down = String.downcase(name)

    cond do
      String.contains?(down, "humane") -> "humane_society"
      String.contains?(down, "rescue") -> "rescue"
      true -> "shelter"
    end
  end

  defp at(_row, nil), do: nil

  defp at(row, index) do
    row |> Enum.at(index) |> presence()
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
