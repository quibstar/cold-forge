defmodule ColdForge.Sourcing.Discovery.Places do
  @moduledoc """
  Google Places API (New). The only discovery source that returns both wide
  coverage of local businesses **and** their website in one response, which is
  why it is the engine and the other three are supplements.

  ## What we keep, and why so little

  Google's Service Specific Terms permit caching `place_id` (per the Places API
  Policies), require cached latitude/longitude to be deleted within 30
  consecutive days, and otherwise prohibit caching Places content. So a
  permanent database *of Google's data* is not on offer, whatever the lead-gen
  videos say.

  It isn't needed. Places is a pointer, not the product: we keep the place id
  as a dedupe key and the website as the thing to go and read, then crawl the
  company's own site and store what *they* publish. That record is ours, it is
  more current than Google's copy, and it is the only version that satisfies
  the rule the whole pipeline exists to keep — an address off the
  organisation's own page, with that page recorded.

  Accordingly `parse/2` deliberately drops rating, review counts, opening
  hours, photos and coordinates. Name, address and phone are kept only as
  fallbacks for a row whose own site turns out to be unreadable, and they live
  in the columns a human reviews rather than anything a campaign merges from.

  ## Cost

  Text Search asking for ids only is free at every tier; the billing starts
  when you ask for fields. Google charges at the highest SKU any requested
  field belongs to, so `field_mask/0` is the cost control, not a detail — it
  asks for id, displayName, formattedAddress, websiteUri,
  nationalPhoneNumber and businessStatus, and nothing else.

  Needs `GOOGLE_PLACES_API_KEY` and an IP-restricted key: a referrer-restricted
  key cannot be used server side, since there is no referrer to match.
  """

  alias ColdForge.Sourcing.Org

  @endpoint "https://places.googleapis.com/v1/places:searchText"

  # Asked for by name so adding a field is a deliberate, costed decision.
  @fields ~w(
    places.id
    places.displayName
    places.formattedAddress
    places.websiteUri
    places.nationalPhoneNumber
    places.businessStatus
  )

  # The search phrases that find each segment. Google matches on its own
  # categories plus the business's own description, which is how it finds the
  # gutter companies OpenStreetMap has no tag for.
  @queries %{
    "roofing" => ["roofing contractor", "roofer"],
    "siding" => ["siding contractor", "siding installation"],
    "windows" => ["window installation", "window and door contractor"],
    "gutters" => ["gutter installation", "seamless gutter contractor"],
    "shelter" => ["animal shelter"],
    "rescue" => ["animal rescue"],
    "humane_society" => ["humane society"],
    "breeder" => ["dog breeder", "cat breeder"]
  }

  # Everyday wording for the built-in segments. Matched after `normalize/1`,
  # so "Windows & Doors", "windows and doors" and "window" all land on the same
  # tuned searches instead of becoming a second, worse search for the same trade.
  @aliases %{
    "roof" => "roofing",
    "roofs" => "roofing",
    "roofer" => "roofing",
    "roofers" => "roofing",
    "roofing contractor" => "roofing",
    "roofing contractors" => "roofing",
    "siding contractor" => "siding",
    "siding contractors" => "siding",
    "window" => "windows",
    "window and door" => "windows",
    "window and doors" => "windows",
    "windows and door" => "windows",
    "windows and doors" => "windows",
    "window installation" => "windows",
    "gutter" => "gutters",
    "seamless gutters" => "gutters",
    "gutter installation" => "gutters",
    "animal shelter" => "shelter",
    "animal shelters" => "shelter",
    "animal rescue" => "rescue",
    "humane society" => "humane_society",
    "breeders" => "breeder"
  }

  def endpoint, do: @endpoint

  @doc """
  The built-in segments. Suggestions, not a limit: anything else is searched as
  typed.
  """
  def segments, do: Map.keys(@queries)

  def field_mask, do: Enum.join(@fields, ",")

  @doc """
  Every phrase searched for a segment.

  A built-in segment uses its tuned phrases. Anything else is the operator's
  own wording, where `|` separates alternative phrasings to search separately:
  `"deck builder | deck contractor"`.
  """
  def queries_for(segment) do
    case Map.fetch(@queries, segment) do
      {:ok, queries} ->
        queries

      :error ->
        segment
        |> to_string()
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  What somebody typed, turned into the segment it is stored as.

  A built-in segment or an alias of one becomes that segment's key; anything
  else is kept as written, tidied, with its `|` alternatives intact.
  """
  def canonical(term) do
    case term
         |> to_string()
         |> String.split("|")
         |> Enum.map(&normalize/1)
         |> Enum.reject(&(&1 == "")) do
      [] ->
        ""

      [one] ->
        key = String.replace(one, " ", "_")

        cond do
          Map.has_key?(@queries, key) -> key
          Map.has_key?(@aliases, one) -> Map.fetch!(@aliases, one)
          true -> one
        end

      phrases ->
        Enum.join(phrases, " | ")
    end
  end

  # Lowercase, quotes gone, "&" spelled out, whitespace collapsed.
  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/["“”']/u, "")
    |> String.replace("&", " and ")
    |> String.replace(~r/[\s_]+/u, " ")
    |> String.trim()
  end

  @doc """
  The request body for one segment in one place, e.g. `"Grand Rapids, MI"`.

  `:page_token` continues a previous response. Text Search returns 20 per page
  and at most 60 for a query, so wide coverage comes from many narrow queries —
  per city, per trade — rather than one broad one.

  `:query` picks which of the segment's phrases to search. Without it, the
  first — which is all this used to search, so a segment's other phrasings
  were listed but never ran.
  """
  @spec search_body(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def search_body(segment, locality, opts \\ []) do
    phrases = queries_for(segment)

    case Keyword.get(opts, :query) || List.first(phrases) do
      nil ->
        {:error, {:unknown_segment, segment}}

      query ->
        body = %{
          "textQuery" => "#{query} in #{locality}",
          "maxResultCount" => Keyword.get(opts, :page_size, 20),
          # Keeps closed businesses out of a send list.
          "includedType" => nil,
          "languageCode" => "en"
        }

        body =
          case Keyword.get(opts, :page_token) do
            nil -> body
            token -> Map.put(body, "pageToken", token)
          end

        {:ok, body |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()}
    end
  end

  @doc """
  Runs one Text Search and returns rows plus the next page token.

  `locality` is anything Google can place, usually `"City, ST"`. Sweeping a
  locality means calling this until the token comes back nil — Text Search caps
  at 60 results per query, so coverage comes from many narrow queries rather
  than one broad one.

  A missing key is `{:error, :no_api_key}` rather than a request with an empty
  one, and an HTTP failure keeps Google's own message, since the useful ones
  ("API keys with referer restrictions cannot be used with this API") say
  exactly what to change.
  """
  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def search(segment, locality, opts \\ []) do
    with {:ok, key} <- api_key(),
         {:ok, body} <- search_body(segment, locality, opts),
         {:ok, %{status: 200, body: response}} <- post(body, key, opts) do
      parse(response, segment)
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, message(body)}}
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(body, key, opts) do
    Req.post(@endpoint,
      json: body,
      headers: [
        {"x-goog-api-key", key},
        {"x-goog-fieldmask", field_mask()}
      ],
      receive_timeout: Keyword.get(opts, :timeout, 20_000),
      retry: false,
      decode_body: true
    )
  end

  defp api_key do
    case Application.get_env(:cold_forge, :google_places_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  # Google puts the useful part in error.message; keep it, and never the key.
  defp message(%{"error" => %{"message" => message}}), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp message(other), do: inspect(other, limit: 5)

  @doc """
  Turns a Places searchText response into rows for `Sourcing.Org`.

  Pure, so it is tested against a saved response. Permanently closed places are
  dropped, and so is anything without a usable name.
  """
  @spec parse(String.t() | map(), String.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def parse(json, segment) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> parse(decoded, segment)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  def parse(%{} = body, segment) do
    places = Map.get(body, "places") || []

    rows =
      places
      |> Enum.map(&place_to_attrs(&1, segment))
      |> Enum.reject(&is_nil/1)

    {:ok, rows, Map.get(body, "nextPageToken")}
  end

  def parse(_other, _segment), do: {:error, :unexpected_shape}

  defp place_to_attrs(%{"id" => id} = place, segment) do
    name = get_in(place, ["displayName", "text"]) |> presence()
    status = Map.get(place, "businessStatus")

    cond do
      is_nil(name) ->
        nil

      # A shut business in a drip campaign is a bounce and a wasted touch.
      status in ["CLOSED_PERMANENTLY"] ->
        nil

      true ->
        %{
          name: name,
          segment: segment,
          website: Org.normalize_website(Map.get(place, "websiteUri")),
          phone: presence(Map.get(place, "nationalPhoneNumber")),
          street: nil,
          city: nil,
          region: nil,
          postal_code: nil,
          country: "US",
          provider: "places",
          source_ref: id,
          # Google's own page for the place, so a reviewer can see what we saw.
          source_url: "https://www.google.com/maps/place/?q=place_id:#{id}",
          # Only what the terms let us keep, plus the formatted address as a
          # human-readable note. No rating, reviews, hours, photos or
          # coordinates: see the moduledoc.
          raw: %{
            "formatted_address" => presence(Map.get(place, "formattedAddress")),
            "business_status" => status
          }
        }
    end
  end

  defp place_to_attrs(_place, _segment), do: nil

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
