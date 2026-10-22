defmodule ColdForge.Sourcing do
  @moduledoc """
  Finding organisations worth writing to, and recording why the rest weren't.

  The flow: a discovery source lists organisations → ones with a website get
  crawled → the ones whose own site publishes an address become prospects, and
  the ones that don't are kept with a reason. Nothing is promoted automatically;
  `promote/2` is called deliberately, because a send list is not a place for
  anything a person hasn't looked at.
  """

  import Ecto.Query

  alias ColdForge.Outreach
  alias ColdForge.Outreach.Prospect
  alias ColdForge.Repo
  alias ColdForge.Sourcing.{Org, Source}
  alias ColdForge.Workers.{CrawlOrg, RunSource}

  ## Sources — saved searches

  @doc "A project's saved searches. Without `:project_id`, every one of them."
  def list_sources(opts \\ []) do
    Source
    |> maybe_project(Keyword.get(opts, :project_id))
    |> order_by([s], asc: s.name)
    |> preload(:project)
    |> Repo.all()
  end

  defp maybe_project(query, nil), do: query
  defp maybe_project(query, project_id), do: where(query, [s], s.project_id == ^project_id)

  def get_source!(id), do: Source |> Repo.get!(id) |> Repo.preload(:project)

  def change_source(%Source{} = source, attrs \\ %{}), do: Source.changeset(source, attrs)

  def create_source(attrs) do
    %Source{} |> Source.changeset(attrs) |> Repo.insert()
  end

  def update_source(%Source{} = source, attrs) do
    source |> Source.changeset(attrs) |> Repo.update()
  end

  def delete_source(%Source{} = source), do: Repo.delete(source)

  @doc """
  Starts a source's search. The work happens in Oban, so the page doesn't wait
  on a provider that may be paginating through several towns.
  """
  def run_source(%Source{} = source) do
    case %{source_id: source.id} |> RunSource.new() |> Oban.insert() do
      {:ok, _job} -> {:ok, source}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Marks a run as started, so the page can say when it last went looking."
  def touch_run(%Source{} = source, summary) do
    source
    |> Ecto.Changeset.change(%{
      last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_run_summary: summary
    })
    |> Repo.update()
  end

  @doc "How a source's organisations are getting on, by status."
  def counts_for_source(%Source{} = source) do
    Org
    |> where([o], o.source_id == ^source.id)
    |> group_by([o], o.status)
    |> select([o], {o.status, count(o.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Stores rows from a discovery source, skipping ones already seen."
  @spec record_discovered([map()]) ::
          {:ok, %{inserted: non_neg_integer(), skipped: non_neg_integer()}}
  def record_discovered(rows) when is_list(rows) do
    {inserted, skipped} =
      Enum.reduce(rows, {0, 0}, fn attrs, {ins, skip} ->
        case %Org{} |> Org.discovery_changeset(attrs) |> Repo.insert() do
          {:ok, _org} -> {ins + 1, skip}
          {:error, _changeset} -> {ins, skip + 1}
        end
      end)

    {:ok, %{inserted: inserted, skipped: skipped}}
  end

  def get_org!(id), do: Repo.get!(Org, id)

  @doc """
  Organisations for the review queue, newest first.

  Options: `:status`, `:segment`, `:limit`.
  """
  def list_orgs(opts \\ []) do
    Org
    |> maybe_status(Keyword.get(opts, :status))
    |> maybe_segment(Keyword.get(opts, :segment))
    |> maybe_source(Keyword.get(opts, :source_id))
    |> order_by([o], desc: o.updated_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  @doc "How many organisations sit at each status, for the queue's tabs."
  def counts_by_status do
    Org
    |> group_by([o], o.status)
    |> select([o], {o.status, count(o.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "The segments actually present, so the filter offers only real options."
  def segments_present do
    Org
    |> distinct(true)
    |> select([o], o.segment)
    |> Repo.all()
    |> Enum.sort()
  end

  defp maybe_source(query, nil), do: query
  defp maybe_source(query, source_id), do: where(query, [o], o.source_id == ^source_id)

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, "all"), do: query
  defp maybe_status(query, status), do: where(query, [o], o.status == ^status)

  @doc "Organisations with a website we haven't crawled yet."
  def crawlable(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Org
    |> where([o], o.status == "discovered" and not is_nil(o.website))
    |> maybe_segment(Keyword.get(opts, :segment))
    |> maybe_source(Keyword.get(opts, :source_id))
    |> order_by([o], asc: o.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, "all"), do: query
  defp maybe_segment(query, segment), do: where(query, [o], o.segment == ^segment)

  @doc "Queues a crawl for each organisation. Returns how many were queued."
  @spec enqueue_crawls([Org.t()]) :: non_neg_integer()
  def enqueue_crawls(orgs) when is_list(orgs) do
    orgs
    |> Enum.map(&CrawlOrg.new(%{org_id: &1.id}))
    |> Enum.count(fn changeset -> match?({:ok, _}, Oban.insert(changeset)) end)
  end

  @doc "Records what the crawl found on an organisation's own site."
  def record_found(%Org{} = org, candidate, result) do
    org
    |> Org.crawl_changeset(%{
      email: candidate.email,
      email_source_url: candidate.source_url,
      email_presentation: to_string(candidate.presentation),
      has_contact_form: result.has_contact_form,
      no_solicitation: false,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "fetched"
    })
    |> Repo.update()
  end

  @doc """
  Records that this organisation is not an email target, and why.

  Not a failure: `no_address_published` is the commonest outcome and it means
  the organisation goes on the call list instead. Most small rescues and
  owner-operated contractors land here.
  """
  def reject(%Org{} = org, reason, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          status: "rejected",
          reject_reason: to_string(reason),
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        extra
      )

    org |> Org.crawl_changeset(attrs) |> Repo.update()
  end

  @doc """
  Makes a prospect of an organisation the crawl found an address for.

  Carries the source URL into `prospect.source`, so the question "where did
  this address come from" is answerable from the send list itself and not only
  from here. An organisation with no address becomes a phone-only prospect when
  it has a number — `Outreach.Prospect` allows that, and the call queue is
  where it belongs.
  """
  def promote(%Org{} = org, project_id) do
    attrs = %{
      project_id: project_id,
      email: org.email,
      company: org.name,
      phone: org.phone,
      website: org.website,
      industry: org.segment,
      source: org.email_source_url || org.source_url,
      notes: promote_notes(org)
    }

    Repo.transaction(fn ->
      with {:ok, prospect} <- Outreach.create_prospect(attrs),
           {:ok, org} <-
             org
             |> Ecto.Changeset.change(%{status: "promoted", prospect_id: prospect.id})
             |> Repo.update() do
        {prospect, org}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  How many of a source's organisations each "Add all" would take, and how many
  websites are still being checked (and may yet turn up an email address).
  """
  def addable_counts(%Source{} = source) do
    %{
      email: source |> addable(:email) |> Repo.aggregate(:count),
      calls: source |> addable(:calls) |> Repo.aggregate(:count),
      checking:
        Org
        |> where([o], o.source_id == ^source.id and o.status == "discovered")
        |> Repo.aggregate(:count)
    }
  end

  @doc """
  Adds every organisation of a source that suits one channel, as prospects of
  its project.

    * `:email` — a published address, website checked, for the drip.
    * `:calls` — a phone and no address, for the call list. This includes the
      places with no website at all, which a search for owner-operated trades
      turns up by the hundred and which used to be left behind entirely.

  Either way, a page asking not to be solicited keeps a place out. Somebody
  already a prospect — matched by email or by phone digits, since Places lists
  the same company once per location — is linked rather than added again.

  Returns `{:ok, %{added: n, existing: n, failed: n}}`. A row that fails is left
  alone, so one bad record can't undo the rest.
  """
  def promote_all(%Source{} = source, kind) when kind in [:email, :calls] do
    totals =
      source
      |> addable(kind)
      |> Repo.all()
      |> Enum.reduce(%{added: 0, existing: 0, failed: 0}, fn org, acc ->
        case existing_prospect(source.project_id, org) do
          nil ->
            case promote(org, source.project_id) do
              {:ok, _} -> Map.update!(acc, :added, &(&1 + 1))
              {:error, _} -> Map.update!(acc, :failed, &(&1 + 1))
            end

          prospect ->
            {:ok, _} =
              org
              |> Ecto.Changeset.change(%{status: "promoted", prospect_id: prospect.id})
              |> Repo.update()

            Map.update!(acc, :existing, &(&1 + 1))
        end
      end)

    {:ok, totals}
  end

  defp addable(%Source{id: source_id}, :email) do
    Org
    |> where([o], o.source_id == ^source_id and o.status == "fetched")
    |> where([o], not o.no_solicitation and not is_nil(o.email) and o.email != "")
  end

  defp addable(%Source{id: source_id}, :calls) do
    Org
    |> where([o], o.source_id == ^source_id and o.status in ["fetched", "needs_website"])
    |> where([o], not o.no_solicitation and (is_nil(o.email) or o.email == ""))
    |> where([o], not is_nil(o.phone) and o.phone != "")
  end

  # Matched on whichever the place has: its email, or its phone's digits, so
  # "(616) 555-0100" and "616-555-0100" are the same shop.
  defp existing_prospect(project_id, %Org{} = org) do
    email = org.email |> to_string() |> String.trim() |> String.downcase()
    digits = phone_digits(org.phone)

    conditions =
      Enum.filter(
        [
          email != "" && dynamic([p], fragment("lower(?)", p.email) == ^email),
          digits != "" &&
            dynamic(
              [p],
              fragment("regexp_replace(coalesce(?, ''), '\\D', '', 'g')", p.phone) == ^digits
            )
        ],
        & &1
      )

    case conditions do
      [] ->
        nil

      [first | rest] ->
        match =
          Enum.reduce(rest, first, fn condition, acc -> dynamic([p], ^acc or ^condition) end)

        Prospect
        |> where([p], p.project_id == ^project_id)
        |> where(^match)
        |> limit(1)
        |> Repo.one()
    end
  end

  defp phone_digits(nil), do: ""
  defp phone_digits(phone), do: String.replace(phone, ~r/\D/, "")

  defp promote_notes(%Org{} = org) do
    [
      "Discovered via #{org.provider}",
      org.email_presentation && "address published as #{org.email_presentation}",
      org.has_contact_form && "site also has a contact form"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("; ")
  end
end
