defmodule ColdForge.Sourcing.Org do
  @moduledoc """
  An organisation discovery turned up, before anyone decides to write to it.

  Staging, not a prospect. Most rows here never become one: no website, no
  published address, or a page asking not to be solicited. Keeping them is the
  point — a row that was rejected records *why*, so the same organisation
  doesn't get rediscovered and re-crawled every month.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  @segments ~w(roofing siding windows gutters shelter rescue humane_society breeder)
  @statuses ~w(discovered needs_website fetched promoted rejected)
  @providers ~w(overpass irs_bmf license_csv places manual)

  @reject_reasons ~w(
    no_website unreachable no_address_published no_solicitation
    out_of_segment duplicate suppressed
  )

  schema "sourcing_orgs" do
    field :name, :string
    field :segment, :string

    field :website, :string
    field :phone, :string
    field :street, :string
    field :city, :string
    field :region, :string
    field :postal_code, :string
    field :country, :string, default: "US"

    # Which discovery module found it. The named search it came from is
    # `source` — a record, not this string.
    field :provider, :string
    field :source_ref, :string
    field :source_url, :string
    field :raw, :map, default: %{}

    field :status, :string, default: "discovered"
    field :reject_reason, :string

    field :email, :string
    field :email_source_url, :string
    field :email_presentation, :string
    field :no_solicitation, :boolean, default: false
    field :notice_text, :string
    field :has_contact_form, :boolean, default: false
    field :fetched_at, :utc_datetime

    belongs_to :source, ColdForge.Sourcing.Source
    belongs_to :prospect, ColdForge.Outreach.Prospect

    timestamps(type: :utc_datetime)
  end

  def segments, do: @segments
  def statuses, do: @statuses
  def providers, do: @providers
  def reject_reasons, do: @reject_reasons

  @doc """
  A row as a discovery source hands it over, before any crawling.
  """
  def discovery_changeset(org, attrs) do
    org
    |> cast(attrs, [
      :name,
      :segment,
      :website,
      :phone,
      :street,
      :city,
      :region,
      :postal_code,
      :country,
      :provider,
      :source_ref,
      :source_url,
      :source_id,
      :raw
    ])
    |> validate_required([:name, :segment, :provider, :source_ref])
    |> validate_inclusion(:segment, @segments)
    |> validate_inclusion(:provider, @providers)
    |> update_change(:website, &normalize_website/1)
    |> put_initial_status()
    |> unique_constraint([:provider, :source_ref],
      name: :sourcing_orgs_source_source_ref_index,
      message: "already discovered from this source"
    )
  end

  @doc "What the crawl found on their site."
  def crawl_changeset(org, attrs) do
    org
    |> cast(attrs, [
      :email,
      :email_source_url,
      :email_presentation,
      :no_solicitation,
      :notice_text,
      :has_contact_form,
      :fetched_at,
      :status,
      :reject_reason
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:reject_reason, @reject_reasons)
  end

  # Without a website there is nothing to crawl, so the row needs a website
  # resolved before it can go any further. That is the usual case for the IRS
  # file and the licence registries, which list organisations but not sites.
  defp put_initial_status(changeset) do
    case get_field(changeset, :website) do
      nil -> put_change(changeset, :status, "needs_website")
      "" -> put_change(changeset, :status, "needs_website")
      _ -> put_change(changeset, :status, "discovered")
    end
  end

  @doc """
  Trims a website down to something fetchable, or nil.

  Sources are inconsistent: bare hosts, missing schemes, a Facebook page in the
  website field. A Facebook or directory URL is not the organisation's own
  site, and an address found on one wouldn't satisfy the rule this whole
  pipeline exists to keep, so it is dropped rather than crawled.
  """
  @not_their_own_site ~w(
    facebook.com m.facebook.com instagram.com twitter.com x.com linkedin.com
    petfinder.com adoptapet.com rescuegroups.org guidestar.org yelp.com
    nextdoor.com angi.com homeadvisor.com bbb.org linktr.ee
  )

  def normalize_website(nil), do: nil

  def normalize_website(url) when is_binary(url) do
    trimmed = String.trim(url)

    with false <- trimmed == "",
         candidate = prepend_scheme(trimmed),
         %URI{host: host} when is_binary(host) <- URI.parse(candidate),
         bare = String.replace_prefix(String.downcase(host), "www.", ""),
         true <- String.contains?(bare, "."),
         false <- bare in @not_their_own_site do
      candidate
    else
      _ -> nil
    end
  end

  defp prepend_scheme(url) do
    if String.match?(url, ~r{^https?://}i), do: url, else: "https://" <> url
  end
end
