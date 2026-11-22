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
  # Added 2026-11-22 after the first run let through "True Air", "ATX Clima",
  # "Mister Sparky", "Dobbs Tennis Courts", realty firms and a flooring store:
  # their permits mention a roof or a window, their trade isn't one.
  @not_a_fit ~W[
    renewal.by.andersen \bpella\b home.depot \blowe'?s\b power.home window.nation
    infinity.replacement solar sunrun \btesla\b plumb electric \belec\b sparky
    mechanical \bhvac\b air.condition \bair\b \ba/?c\b clima temperature
    heating \bheat\b cooling \bpools?\b \bpest\b landscap fire.protection sprinkler
    \bmist\b water.services pipework \bpipe tennis foundation.(repair|special)
    realty \bproperties\b investments? capital.group \bsells\b flooring \bbath\b
    fabrication environmental facilit(y|ies) network.services \bpermits?\b petro
    appliance consulting
  ]

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

  # San Antonio's export cuts the company at 30 characters: "Garcia's
  # Remodeling & Construc", "IRC Roofing & Construction, Ll".
  @san_antonio_name_limit 30

  defp contractor("austin", record) do
    raw = basic_clean(record["contractor_company_name"])
    company = clean_name(record["contractor_company_name"])

    # A person's own name in the company field is a homeowner pulling their
    # own permit, as often as not, and there's no business to look up.
    if fit?(company) and not person?(raw, record["contractor_full_name"]) do
      %{
        key: normalize(raw),
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
        raw = basic_clean(company)
        # Exactly at the limit: a name that ran into it. "III, VINTAGE
        # RECONSTRUCTION, INC" is longer only because the split put the
        # person's suffix in front of it.
        truncated = String.length(String.trim(company)) == @san_antonio_name_limit
        company = company |> strip_name_suffix() |> clean_name() |> untruncate(truncated)

        if fit?(company) do
          %{
            key: normalize(raw),
            company: company,
            truncated: truncated,
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

  # "MIKE HOWELL, JR, HOWELL ENTERPRISES" splits after the name, leaving the
  # suffix at the front of the company.
  defp strip_name_suffix(company),
    do: String.replace(company, ~r/^\s*(jr|sr|ii|iii|iv)\.?\s*,\s*/i, "")

  # A cut-off name loses its last, partial word and whatever it leaves dangling.
  defp untruncate(nil, _truncated), do: nil
  defp untruncate(name, false), do: name

  defp untruncate(name, true) do
    name
    |> String.split(" ")
    |> Enum.drop(-1)
    |> Enum.join(" ")
    |> String.replace(~r/[\s,&]+$|\s+(and|of|the)$/i, "")
    |> String.trim()
    |> case do
      "" -> name
      shorter -> shorter
    end
  end

  defp person?(nil, _full_name), do: false
  defp person?(_company, nil), do: false

  defp person?(company, full_name),
    do: normalize(company) == normalize(full_name) and String.contains?(normalize(company), "-")

  defp to_org(city_key, city, segment, key, rows) do
    busiest = Enum.max_by(rows, & &1.permits)
    phone = rows |> Enum.map(& &1.phone) |> most_common()
    person = rows |> Enum.map(& &1.person) |> most_common()
    last = rows |> Enum.map(& &1.last) |> Enum.reject(&is_nil/1) |> Enum.max(Date, fn -> nil end)

    truncated = Enum.any?(rows, &Map.get(&1, :truncated, false))

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
      raw:
        %{
          "permit_city" => city.name,
          "permits" => Enum.sum(Enum.map(rows, & &1.permits)),
          "last_issued" => last && Date.to_iso8601(last),
          "contact_name" => person
        }
        |> then(&if(truncated, do: Map.put(&1, "name_truncated", true), else: &1))
    }
  end

  defp fit?(nil), do: false
  defp fit?(""), do: false

  defp fit?(company) do
    not junk_name?(company) and trade_fits?(company)
  end

  # What's left when the city put only a suffix where the company goes: "JR",
  # "INC".
  defp junk_name?(name), do: String.match?(name, ~r/^(jr|sr|ii|iii|iv|inc|llc|co)\.?$/i)

  defp trade_fits?(company) do
    not_a_fit = Regex.compile!(Enum.join(@not_a_fit, "|"), "i")
    not_a_contractor = Regex.compile!("^(" <> Enum.join(@not_a_contractor, "|") <> ")\\b", "i")
    not Regex.match?(not_a_fit, company) and not Regex.match?(not_a_contractor, company)
  end

  @doc """
  A company name as an email would write it: the city's bookkeeping removed
  ("**Main**", "(MAIN)", "(d/b/a or registered trade name)"), the trading name
  when it gives both ("GDM LLC dba Big Tex Construction" is Big Tex
  Construction), no "LLC" or "Inc." on the end, and normal capitals for a name
  written in capitals, keeping initials like "DV" and "IRC".
  """
  def clean_name(name) do
    case basic_clean(name) do
      nil ->
        nil

      basic ->
        basic
        |> trading_name()
        |> String.replace(~r/\((main|[^)]*\b(llc|inc|partners?)\b[^)]*)\)/i, "")
        |> squeeze()
        |> strip_legal()
        |> case do
          "" -> nil
          display -> if shouting?(basic), do: title_case(display), else: display
        end
    end
  end

  @doc """
  The city's own bookkeeping off a name, and nothing else. A contractor's key
  is made from this, so it doesn't move when the display rules change: a new
  rule must not make every known contractor look new on the next run.
  """
  def basic_clean(nil), do: nil

  def basic_clean(name) do
    name
    |> String.replace(~r/\*+\s*main\s*\*+/i, "")
    |> String.replace(~r/\(d\/b\/a[^)]*\)/i, "")
    |> String.replace(~r/,(?=\S)/, ", ")
    |> squeeze()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp squeeze(name) do
    name
    |> String.replace(~r/[\s\x{00A0}]+/u, " ")
    |> String.trim()
    |> String.trim(",")
    |> String.trim()
  end

  defp trading_name(name) do
    case Regex.run(~r/\b(?:dba|d\/b\/a)\b[:.]?\s*(.+)$/i, name) do
      [_, trading] -> if String.trim(trading) == "", do: name, else: trading
      nil -> name
    end
  end

  # "Quick Roofing LLC on Austin's permit list" reads as a form letter.
  # "Company" stays: "Gary Werner" alone reads as a person.
  @legal ~r/(^|[,\s]+)(l\.?l\.?c\.?|inc\.?|incorporated|corp\.?|corporation|ltd\.?|l\.?p\.?|llp|pllc|co\.?)$/i

  defp strip_legal(name) do
    stripped = name |> String.replace(@legal, "") |> squeeze()
    if stripped == name, do: name, else: strip_legal(stripped)
  end

  # "QUICK ROOFING LLC" reads as shouting in an email's greeting line.
  defp shouting?(name), do: name == String.upcase(name) and name =~ ~r/[A-Z]{3}/

  @abbreviations ~w(LLC LP LLP PLLC II III IV USA TX ATX)

  # Short words that are words, not initials: "TOP ROOFING" is Top Roofing,
  # while "DV ROOFING" and "IRC ROOFING" keep their initials.
  @short_words ~w(a an and the of on in at by for to or & all one two six ten top pro max
                  big old new man son sons ace sky sun bay air art red oak elm fix way bar
                  box cat dog fox hat hot ice key lab map oil owl pen pet pin rod row run saw
                  sea set tex tin tip van war web win zen eco gem hub jet kid mid ray rex rio
                  guy bob joe tom sam ted tim ben dan don lee rob jim jon kim roy amy ana ava
                  eva mia sue god usa)

  defp title_case(name) do
    name
    |> String.split(" ")
    |> Enum.map_join(" ", fn word ->
      bare = String.trim(word, ",")
      letters = String.replace(bare, ~r/[^A-Za-z]/, "")

      cond do
        bare in @abbreviations -> word
        initials?(letters) -> word
        true -> word |> String.downcase() |> capitalize_parts()
      end
    end)
  end

  # Two or three letters that aren't a word, or a run of consonants: "DV",
  # "IRC", "BLDT".
  defp initials?(""), do: false

  defp initials?(letters) do
    down = String.downcase(letters)

    (String.length(letters) <= 3 and down not in @short_words) or
      (String.length(letters) <= 4 and not String.match?(down, ~r/[aeiouy]/))
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
