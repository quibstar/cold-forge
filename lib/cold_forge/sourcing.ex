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
  alias ColdForge.Repo
  alias ColdForge.Sourcing.Org
  alias ColdForge.Workers.CrawlOrg

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

  @doc "Organisations with a website we haven't crawled yet."
  def crawlable(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Org
    |> where([o], o.status == "discovered" and not is_nil(o.website))
    |> maybe_segment(Keyword.get(opts, :segment))
    |> order_by([o], asc: o.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_segment(query, nil), do: query
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

  defp promote_notes(%Org{} = org) do
    [
      "Discovered via #{org.source}",
      org.email_presentation && "address published as #{org.email_presentation}",
      org.has_contact_form && "site also has a contact form"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("; ")
  end
end
