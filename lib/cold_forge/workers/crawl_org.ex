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
  stop costing us attempts — and on the last one, whatever went wrong, the
  place is settled as unreachable rather than left "checking" for ever, which
  is what kept a finished Michigan run saying 64 left.
  """

  # One check per place at a time. Without this every finished search re-queued
  # the same places, and a Michigan run built a queue of 105,875 checks for
  # about 1,600 websites.
  use Oban.Worker,
    queue: :crawl,
    max_attempts: 3,
    unique: [keys: [:org_id], states: :incomplete, period: :infinity]

  # A gap we will sit out in the job rather than requeueing for. Covers the
  # default per-host pace; anything longer than this is a site asking for real
  # patience, and that belongs on the queue.
  @inline_wait_ms 5_000

  # Once a page has been read, a snooze would start the site over from its
  # homepage — and a site that asks for a long gap between pages would then
  # loop for ever, reading its homepage and snoozing. So past the first page
  # the gap is waited out here, up to this long; a site asking for more than
  # a minute between pages gets what was read so far.
  @max_wait_after_first_page_ms 60_000

  require Logger

  alias ColdForge.Sourcing
  alias ColdForge.Sourcing.{Extractor, Fetcher, Org}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}} = job) do
    check(org_id)
  rescue
    error ->
      if job.attempt >= job.max_attempts do
        Logger.warning(
          "sourcing: giving up on #{org_id} after #{job.attempt} tries — " <>
            Exception.format_banner(:error, error, __STACKTRACE__)
        )

        give_up(org_id)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp give_up(org_id) do
    case Sourcing.get_org(org_id) do
      %Org{status: "discovered"} = org ->
        {:ok, _} = Sourcing.record_unreachable(org)
        :ok

      _settled_or_gone ->
        :ok
    end
  end

  defp check(org_id) do
    case Sourcing.get_org!(org_id) do
      %Org{status: status} when status in ["rejected", "promoted"] ->
        # Already settled; a duplicate job shouldn't re-crawl.
        :ok

      %Org{website: nil} = org ->
        {:ok, _} = Sourcing.reject(org, :no_website)
        :ok

      %Org{} = org ->
        crawl(org, Fetcher.candidate_urls(org.website), false)
    end
  end

  # Out of pages to try: nothing published. Not a failure — it is the answer
  # for most owner-operated contractors and small rescues, and it is what puts
  # them on the call list instead.
  defp crawl(org, [], _read_one?) do
    {:ok, _} = Sourcing.record_nothing_found(org)
    :ok
  end

  defp crawl(org, [url | rest], read_one?) do
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
            crawl(note_form(org, result), rest, true)
        end

      # The host was hit too recently. Every candidate page is on the same host,
      # so a short gap is waited out here: snoozing instead would cost one job
      # attempt per page and a four-page site would exhaust max_attempts before
      # reaching its contact page. A long gap — a site asking for a big
      # Crawl-delay — goes back on the queue rather than parking a worker.
      {:error, {:wait, ms}} when ms <= @inline_wait_ms ->
        Process.sleep(ms)
        crawl(org, [url | rest], read_one?)

      # Nothing read yet, so nothing lost by starting over later.
      {:error, {:wait, ms}} when not read_one? ->
        {:snooze, max(div(ms, 1000), 1)}

      {:error, {:wait, ms}} when ms <= @max_wait_after_first_page_ms ->
        Process.sleep(ms)
        crawl(org, [url | rest], read_one?)

      {:error, {:wait, _ms}} ->
        crawl(org, [], read_one?)

      {:error, :disallowed_by_robots} ->
        # Only this path is forbidden; another might not be.
        crawl(org, rest, read_one?)

      {:error, reason} ->
        Logger.debug("sourcing: #{url} unavailable (#{inspect(reason)})")
        crawl(org, rest, read_one?)
    end
  end

  defp note_form(org, %{has_contact_form: true}), do: %{org | has_contact_form: true}
  defp note_form(org, _result), do: org
end
