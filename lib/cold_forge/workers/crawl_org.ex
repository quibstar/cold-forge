defmodule ColdForge.Workers.CrawlOrg do
  @moduledoc """
  Reads one organisation's own website looking for a published address.

  Tries the homepage first, then the pages that exist to be written to, and
  stops at the first address found — there is no reason to fetch four pages of
  a site that put the address in its footer.

  Three outcomes, and the middle one is the most common:

    * an address, recorded with the exact page it was on
    * no address published, so the organisation goes to the call list
    * a notice asking not to be solicited, which takes it off both lists

  Snoozes rather than sleeps when the host was hit too recently, so one slow
  host cannot occupy a worker. `max_attempts` is low because the failures worth
  retrying are transient by definition; a site that is genuinely gone should
  stop costing us attempts.
  """

  use Oban.Worker, queue: :crawl, max_attempts: 3

  # A gap we will sit out in the job rather than requeueing for. Covers the
  # default per-host pace; anything longer than this is a site asking for real
  # patience, and that belongs on the queue.
  @inline_wait_ms 5_000

  require Logger

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Extractor, Fetcher, Org}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) do
    case Sourcing.get_org!(org_id) do
      %Org{status: status} when status in ["rejected", "promoted"] ->
        # Already settled; a duplicate job shouldn't re-crawl.
        :ok

      %Org{website: nil} = org ->
        {:ok, _} = Sourcing.reject(org, :no_website)
        :ok

      %Org{} = org ->
        crawl(org, Fetcher.candidate_urls(org.website))
    end
  end

  # Out of pages to try: nothing published. Not a failure — it is the answer
  # for most owner-operated contractors and small rescues, and it is what puts
  # them on the call list instead.
  defp crawl(org, []) do
    {:ok, _} = Sourcing.record_nothing_found(org)
    :ok
  end

  defp crawl(org, [url | rest]) do
    case Fetcher.fetch(url) do
      {:ok, %{body: body}} ->
        result = Extractor.extract(body, url)

        cond do
          result.no_solicitation ->
            {:ok, _} =
              Sourcing.reject(org, :no_solicitation, %{
                no_solicitation: true,
                notice_text: result.notice_text,
                has_contact_form: result.has_contact_form
              })

            :ok

          candidate = Extractor.best(result) ->
            {:ok, _} = Sourcing.record_found(org, candidate, result)
            :ok

          true ->
            # Nothing here; remember a contact form if we saw one, then move on.
            crawl(note_form(org, result), rest)
        end

      # The host was hit too recently. Every candidate page is on the same host,
      # so a short gap is waited out here: snoozing instead would cost one job
      # attempt per page and a four-page site would exhaust max_attempts before
      # reaching its contact page. A long gap — a site asking for a big
      # Crawl-delay — goes back on the queue rather than parking a worker.
      {:error, {:wait, ms}} when ms <= @inline_wait_ms ->
        Process.sleep(ms)
        crawl(org, [url | rest])

      {:error, {:wait, ms}} ->
        {:snooze, max(div(ms, 1000), 1)}

      {:error, :disallowed_by_robots} ->
        # Only this path is forbidden; another might not be.
        crawl(org, rest)

      {:error, reason} ->
        Logger.debug("sourcing: #{url} unavailable (#{inspect(reason)})")
        crawl(org, rest)
    end
  end

  defp note_form(org, %{has_contact_form: true}), do: %{org | has_contact_form: true}
  defp note_form(org, _result), do: org
end
