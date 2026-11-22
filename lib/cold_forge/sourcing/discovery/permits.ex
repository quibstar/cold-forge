defmodule ColdForge.Sourcing.Discovery.Permits do
  @moduledoc """
  City building permits: the contractors who pulled roofing, siding, window or
  gutter permits lately.

  The opposite of a directory. Places lists whoever has a listing; a permit
  feed lists whoever is actually doing the work, and how much of it. A shop
  that pulled thirty reroof permits last quarter is busy, and busy is who
  outgrows the whiteboard.

  Only cities whose open data names the contractor are here, which is fewer
  than it sounds (checked 2026-11-22):

    * **Austin** names the contractor's company, the person and a phone on
      every issued permit. The best of them.
    * **San Antonio** lists one "primary contact" per permit, written
      "PERSON, COMPANY" when it's a company. Rows with no company are left
      out: a person's name alone can't be looked up, and is as likely the
      homeowner as the roofer.
    * Dallas stopped publishing the contractor in September 2025, Houston
      publishes monthly totals only, and Fort Worth's feed stopped in July
      2025.

  One row per contractor per city, never per permit, and nothing about the
  homeowner or the address worked on: what's kept is the company, the person
  the city lists, their phone, how many permits and the latest one's date.

  Rows have no website, so they land as `needs_website`; the website lookup
  (`ColdForge.Workers.FindWebsite`) finds one from Places before the crawl can
  look for an address.
  """

  alias ColdForge.Sourcing.Fetcher

  @segments ~w(roofing siding windows gutters)

  # How far back each run reads. Contractors already found are skipped by
  # their source_ref, so a weekly run only adds the ones new since.
  @lookback_days 90

  @cities %{
    "austin" => %{
      name: "Austin",
      region: "TX",
      kind: :socrata,
      url: "https://data.austintexas.gov/resource/3syk-w9eu.json",
      page: "https://data.austintexas.gov/d/3syk-w9eu"
    },
    "san_antonio" => %{
      name: "San Antonio",
      region: "TX",
      kind: :ckan,
      url: "https://data.sanantonio.gov/api/3/action/datastore_search_sql",
      resource: "c21106f9-3ef5-4f3a-8604-f992b4db7512",
      page: "https://data.sanantonio.gov/dataset/building-permits"
    }
  }

  # National chains and other trades that pull window or roof permits: not an
  # owner-operated exterior shop, and not who ExteriorPro is for.
  @not_a_fit ~W(
    renewal.by.andersen \bpella\b home.depot \blowe'?s\b power.home window.nation
    solar sunrun \btesla\b plumb electric mechanical \bhvac\b air.condition heating
    cooling \bpools?\b \bpest\b landscap fire.protection sprinkler
  )

  # What the city puts where a contractor should be when there isn't one.
  @not_a_contractor ~W(owner home.?owner self n/?a none tbd unknown)

  def segments, do: @segments
  def cities, do: Map.keys(@cities)
  def city(key), do: Map.get(@cities, key)
  def city_name(key), do: get_in(@cities, [key, :name]) || key
  def lookback_days, do: @lookback_days

  @doc """
  Contractors in one city with permits for one trade in the last
  #{@lookback_days} days, as rows for `Sourcing.Org`.
  """
  @spec fetch(String.t(), String.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch(city_key, segment, today \\ Date.utc_today()) do
    since = Date.add(today, -@lookback_days)

    with %{} = city <- city(city_key) || {:error, {:unknown_city, city_key}},
         true <- segment in @segments || {:error, {:unknown_segment, segment}},
         {:ok, records} <- request(city, segment, since) do
      {:ok, parse(city_key, segment, records)}
    end
  end

  defp request(%{kind: :socrata, url: url}, segment, since) do
    get(url, austin_params(segment, since), fn body -> {:ok, body} end)
  end

  defp request(%{kind: :ckan, url: url, resource: resource}, segment, since) do
    get(url, [sql: san_antonio_sql(resource, segment, since)], fn
      %{"success" => true, "result" => %{"records" => records}} -> {:ok, records}
      other -> {:error, {:unexpected, inspect(other, limit: 5)}}
    end)
  end

  defp get(url, params, handle) do
    case Req.get(url,
           params: params,
           headers: [{"user-agent", Fetcher.user_agent()}],
           receive_timeout: 60_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> handle.(body)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc "Austin's query: one row per contractor, counted, for one trade."
  def austin_params(segment, %Date{} = since) do
    [
      "$select":
        "contractor_company_name, contractor_full_name, contractor_phone, contractor_city, " <>
          "count(*) as permits, max(issue_date) as last_issued",
      "$where": "issue_date >= '#{Date.to_iso8601(since)}' AND #{austin_match(segment)}",
      "$group":
        "contractor_company_name, contractor_full_name, contractor_phone, contractor_city",
      "$limit": 5000
    ]
  end

  defp austin_match("roofing"),
    do: "upper(description) like '%ROOF%' AND upper(description) not like '%SOLAR%'"

  defp austin_match("siding"), do: "upper(description) like '%SIDING%'"
  defp austin_match("windows"), do: "upper(description) like '%WINDOW%'"
  defp austin_match("gutters"), do: "upper(description) like '%GUTTER%'"

  @doc "San Antonio's query: one row per primary contact, counted, for one trade."
  def san_antonio_sql(resource, segment, %Date{} = since) do
    ~s|SELECT "PRIMARY CONTACT" AS contact, count(*) AS permits, max("DATE ISSUED") AS last_issued | <>
      ~s|FROM "#{resource}" WHERE "DATE ISSUED" >= '#{Date.to_iso8601(since)}' | <>
      ~s|AND #{san_antonio_match(segment)} GROUP BY 1|
  end

  defp san_antonio_match("roofing"), do: ~s|"PERMIT TYPE" ILIKE '%roof%'|
  defp san_antonio_match("siding"), do: ~s|"PROJECT NAME" ILIKE '%siding%'|
  defp san_antonio_match("windows"), do: ~s|"PROJECT NAME" ILIKE '%window%'|
  defp san_antonio_match("gutters"), do: ~s|"PROJECT NAME" ILIKE '%gutter%'|

  @doc """
  The city's grouped records as Org rows: one per contractor, the busiest
  phone and person kept, chains and other trades dropped. Pure, for tests.
  """
  def parse(city_key, segment, records) when is_list(records) do
    city = city(city_key)

    records
    |> Enum.map(&contractor(city_key, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, rows} -> to_org(city_key, city, segment, key, rows) end)
    |> Enum.sort_by(& &1.raw["permits"], :desc)
  end

  defp contractor("austin", record) do
    company = clean_name(record["contractor_company_name"])

    if fit?(company) do
      %{
        key: normalize(company),
        company: company,
        person: titleize(record["contractor_full_name"]),
        phone: phone(record["contractor_phone"]),
        town: titleize(record["contractor_city"]),
        permits: to_int(record["permits"]),
        last: date(record["last_issued"])
      }
    end
  end

  defp contractor("san_antonio", record) do
    case String.split(to_string(record["contact"]), ",", parts: 2) do
      [person, company] ->
        company = clean_name(company)

        if fit?(company) do
          %{
            key: normalize(company),
            company: company,
            person: titleize(person),
            phone: nil,
            town: nil,
            permits: to_int(record["permits"]),
            last: date(record["last_issued"])
          }
        end

      # A person and no company: can't be looked up, and may be the homeowner.
      _ ->
        nil
    end
  end

  defp to_org(city_key, city, segment, key, rows) do
    busiest = Enum.max_by(rows, & &1.permits)
    phone = rows |> Enum.map(& &1.phone) |> most_common()
    person = rows |> Enum.map(& &1.person) |> most_common()
    last = rows |> Enum.map(& &1.last) |> Enum.reject(&is_nil/1) |> Enum.max(Date, fn -> nil end)

    %{
      name: busiest.company,
      segment: segment,
      phone: phone,
      city: busiest.town || city.name,
      region: city.region,
      country: "US",
      provider: "permits",
      source_ref: "#{city_key}:#{key}",
      source_url: city.page,
      raw: %{
        "permit_city" => city.name,
        "permits" => Enum.sum(Enum.map(rows, & &1.permits)),
        "last_issued" => last && Date.to_iso8601(last),
        "contact_name" => person
      }
    }
  end

  defp fit?(nil), do: false
  defp fit?(""), do: false

  defp fit?(company) do
    not_a_fit = Regex.compile!(Enum.join(@not_a_fit, "|"), "i")
    not_a_contractor = Regex.compile!("^(" <> Enum.join(@not_a_contractor, "|") <> ")\\b", "i")
    not Regex.match?(not_a_fit, company) and not Regex.match?(not_a_contractor, company)
  end

  @doc """
  A company name as the city wrote it, minus its own bookkeeping: "**Main**",
  "*MAIN*" and "(d/b/a or registered trade name)".
  """
  def clean_name(nil), do: nil

  def clean_name(name) do
    name
    |> String.replace(~r/\*+\s*main\s*\*+/i, "")
    |> String.replace(~r/\(d\/b\/a[^)]*\)/i, "")
    |> String.replace(~r/,(?=\S)/, ", ")
    |> String.replace(~r/[\s\x{00A0}]+/u, " ")
    |> String.trim()
    |> String.trim(",")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> if shouting?(cleaned), do: title_case(cleaned), else: cleaned
    end
  end

  # "QUICK ROOFING LLC" reads as shouting in an email's greeting line.
  defp shouting?(name), do: name == String.upcase(name) and name =~ ~r/[A-Z]{3}/

  @abbreviations ~w(LLC LP LLP PLLC II III IV USA TX)

  defp title_case(name) do
    name
    |> String.split(" ")
    |> Enum.map_join(" ", fn word ->
      if String.trim(word, ",") in @abbreviations,
        do: word,
        else: word |> String.downcase() |> capitalize_parts()
    end)
  end

  # "SOUKUP ROOFING,LLC" and "A-1 GUTTERS" keep their joins.
  defp capitalize_parts(word) do
    Regex.replace(~r/(^|[-,\/&])([a-z])/, word, fn _, sep, letter ->
      sep <> String.upcase(letter)
    end)
  end

  @doc "The key one contractor is known by, however the city spelled it this time."
  def normalize(name) do
    name
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/[^a-z0-9 ]/, " ")
    |> String.replace(
      ~r/\b(llc|l l c|inc|incorporated|co|corp|corporation|ltd|lp|llp|pllc|the)\b/,
      " "
    )
    |> String.split()
    |> Enum.join("-")
  end

  defp most_common(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_value, n} -> n end, fn -> {nil, 0} end)
    |> elem(0)
  end

  defp phone(nil), do: nil

  defp phone(value) do
    case String.replace(value, ~r/\D/, "") do
      <<"1", rest::binary-size(10)>> -> format_phone(rest)
      <<digits::binary-size(10)>> -> format_phone(digits)
      _ -> nil
    end
  end

  defp format_phone(<<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  defp titleize(nil), do: nil

  defp titleize(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        if trimmed == String.upcase(trimmed),
          do:
            trimmed
            |> String.downcase()
            |> String.split()
            |> Enum.map_join(" ", &String.capitalize/1),
          else: trimmed |> String.split() |> Enum.join(" ")
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: n |> Integer.parse() |> then(fn {i, _} -> i end)
  defp to_int(_), do: 0

  defp date(nil), do: nil

  defp date(value) do
    case value |> to_string() |> String.slice(0, 10) |> Date.from_iso8601() do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
