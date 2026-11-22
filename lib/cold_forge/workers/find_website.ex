defmodule ColdForge.Workers.FindWebsite do
  @moduledoc """
  Finds the website of an organisation a registry listed without one, so the
  crawl can look for a published address on it.

  Permit feeds name the contractor and often their phone, never a website. One
  Places text search for the name in its city usually turns it up. A result is
  only taken when it's plainly the same business: the same phone digits, or
  the same name once "LLC" and punctuation are set aside. A near miss is worse
  than nothing: it would put another company's address on the send list.

  Not found stays `needs_website`, which is the call list's tab: the city
  usually gave a phone number even when there's no site.

  One Places request per organisation, at the Enterprise rate (website and
  phone fields), so this only runs for permit rows, not every needs_website
  row the IRS file ever produced.
  """
  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [keys: [:org_id], states: :incomplete, period: :infinity]

  require Logger

  alias ColdForge.Repo
  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.Discovery.{Permits, Places}
  alias ColdForge.Sourcing.Org

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) do
    case Repo.get(Org, org_id) do
      %Org{status: "needs_website"} = org -> look_up(org)
      # Already resolved, promoted or rejected since this was queued.
      _ -> :ok
    end
  end

  defp look_up(%Org{} = org) do
    locality = Enum.join(Enum.reject([org.city, org.region], &(&1 in [nil, ""])), ", ")

    case Places.search(org.segment, locality, query: org.name, page_size: 5) do
      {:ok, rows, _next} ->
        case pick_match(org, rows) do
          nil ->
            Logger.info("find website: no match for #{org.name} (#{locality})")
            :ok

          match ->
            {:ok, org} = Sourcing.record_website(org, with_name(org, match))
            Sourcing.enqueue_crawls([org])
            :ok
        end

      {:error, :no_api_key} ->
        {:cancel, :no_api_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The Places row that is this organisation, or nil. Needs a website, and
  either the same phone digits or the same name once normalised. Pure.
  """
  def pick_match(%Org{} = org, rows) do
    digits = digits(org.phone)
    name = Permits.normalize(org.name)

    rows
    |> Enum.filter(&(is_binary(&1[:website]) and &1[:website] != ""))
    # Same name, another state: "Tony's Roofing" in Tucson, "Arki Design" in
    # Australia. Both happened on the first run.
    |> Enum.filter(&(is_nil(&1[:region]) or is_nil(org.region) or &1[:region] == org.region))
    |> Enum.find(fn row ->
      (digits != "" and digits(row[:phone]) == digits) or same_name?(name, row[:name])
    end)
  end

  @doc """
  The listing's own name, for a row the city cut short ("Garcia's Remodeling
  & Construc"), when the listing is plainly the same business. Anything after
  a colon or a dash is the listing's advertising, not its name.
  """
  def with_name(%Org{raw: %{"name_truncated" => true}} = org, match) do
    listed =
      (match[:name] || "")
      |> String.split(~r/\s[:|\-–]\s|:\s/, parts: 2)
      |> hd()
      |> Permits.clean_name()

    if listed && same_name?(Permits.normalize(org.name), listed),
      do: Map.put(match, :rename, listed),
      else: match
  end

  def with_name(_org, match), do: match

  defp same_name?(_name, nil), do: false
  defp same_name?("", _other), do: false

  defp same_name?(name, other) do
    other = Permits.normalize(other)
    # "summit-roofing" and "summit-roofing-and-restoration" are one shop; a
    # one-word name like "summit" is too common to match on a prefix.
    other == name or
      (String.contains?(name, "-") and String.contains?(other, "-") and
         (String.starts_with?(other, name <> "-") or String.starts_with?(name, other <> "-")))
  end

  defp digits(nil), do: ""

  defp digits(phone) do
    case String.replace(phone, ~r/\D/, "") do
      <<"1", rest::binary-size(10)>> -> rest
      digits -> digits
    end
  end
end
