defmodule ColdForge.Sourcing.KindCheck do
  @moduledoc """
  Whether a breeder search result's own website reads like a breeder.

  Google files plenty of breeders under pet care, boarding or pet store, the
  same as groomers and daycares, and neither its type nor the business name
  told them apart: of 47 groomers, boarders, daycares and trainers found in the
  dog breeder drips in November 2026, a name check caught none. Their websites
  did.

  Words, not judgement, so it holds a place for a person to look at rather
  than dropping it. Tested on those drips' 891 contacts, this rule held 40 of
  the 47 and 35 others, several of which were also boarders.
  """

  @breeder_words ~r/pupp(?:y|ies)|litter|breeder|breeding|\bakc\b|\bukc\b|\bsire|\bstud\b|deposit|wait ?list|champion|pedigree|kennel|kitten|cattery/
  @service_words ~r/grooming|boarding|daycare|day care|veterinar|animal hospital|obedience|dog training|pet supplies/

  # At least this many service words, and more of them than breeder words.
  @min_service 5

  @doc """
  `{:hold, note}` when a breeder search result's pages look like a pet service
  rather than a breeder, `:ok` otherwise. Other searches are never held.
  `pages` are the HTML bodies the crawl read.
  """
  @spec check(String.t() | nil, [String.t()]) :: :ok | {:hold, String.t()}
  def check(segment, pages) do
    if breeder_search?(segment), do: judge(pages), else: :ok
  end

  defp breeder_search?(segment), do: to_string(segment) =~ ~r/breeder/i

  defp judge(pages) do
    text = pages |> Enum.join(" ") |> String.downcase()
    service = tally(@service_words, text)
    breeder = tally(@breeder_words, text) |> Map.values() |> Enum.sum()
    service_total = service |> Map.values() |> Enum.sum()

    if service_total >= @min_service and service_total > breeder do
      {:hold, note(service)}
    else
      :ok
    end
  end

  defp tally(regex, text) do
    regex
    |> Regex.scan(text)
    |> Enum.map(fn [word | _] -> word end)
    |> Enum.frequencies()
  end

  # "Website reads like grooming and boarding, not breeding": the two words it
  # used most, so the reviewer knows what to look for.
  defp note(service) do
    top =
      service
      |> Enum.sort_by(fn {_word, n} -> -n end)
      |> Enum.take(2)
      |> Enum.map(fn {word, _} -> word end)
      |> Enum.join(" and ")

    "Website reads like #{top}, not breeding"
  end
end
