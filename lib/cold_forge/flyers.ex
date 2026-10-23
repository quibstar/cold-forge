defmodule ColdForge.Flyers do
  @moduledoc """
  Printed counter flyers: what they say, where they're put up, and which ones
  get scanned.

  The flyer is the cheap part. The value is the conversation that gets it put
  up — a branch manager who knows every contractor in the territory — so a
  placement carries a status and notes for that conversation, not just a code.
  """
  import Ecto.Query, warn: false

  alias ColdForge.Flyers.{Content, Placement, Scan}
  alias ColdForge.Outreach.Project
  alias ColdForge.Repo
  alias ColdForge.Sourcing.{Org, Source}

  ## What the flyer says

  @doc "The project's flyer content, empty if it has none yet."
  def content(%Project{flyer: %Content{} = content}), do: content
  def content(%Project{}), do: %Content{}

  def change_content(%Project{} = project, attrs \\ %{}),
    do: Content.changeset(content(project), attrs)

  # cast_embed rather than put_embed: the embed updates in place, and a
  # replacement changeset is refused for an embed that already exists.
  def update_content(%Project{} = project, attrs) do
    project
    |> Ecto.Changeset.cast(%{"flyer" => attrs}, [])
    |> Ecto.Changeset.cast_embed(:flyer, with: &Content.changeset/2, required: true)
    |> Repo.update()
  end

  ## Where flyers are put up

  def list_placements(project_id) do
    Placement
    |> where([p], p.project_id == ^project_id)
    |> order_by([p], desc: p.scans_count, asc: p.venue_name)
    |> Repo.all()
  end

  def get_placement!(id), do: Repo.get!(Placement, id)

  def get_placements(project_id, ids) when is_list(ids) do
    Placement
    |> where([p], p.project_id == ^project_id and p.id in ^ids)
    |> order_by([p], asc: p.venue_name)
    |> Repo.all()
  end

  def change_placement(%Placement{} = placement, attrs \\ %{}),
    do: Placement.changeset(placement, attrs)

  @doc """
  Adds a place to put a flyer. The code is made from the name and town
  ("ABC Supply", "Wyoming, MI" → `abc-supply-wyoming`) unless one is given.
  """
  def create_placement(%Project{} = project, attrs, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    code =
      case attrs["code"] do
        code when is_binary(code) and code != "" -> code
        _ -> unique_code(attrs["venue_name"], attrs["address"])
      end

    # The org link is set here, never cast: it isn't something a form posts.
    %Placement{project_id: project.id, org_id: Keyword.get(opts, :org_id)}
    |> Placement.create_changeset(Map.put(attrs, "code", code))
    |> Repo.insert()
  end

  def update_placement(%Placement{} = placement, attrs) do
    placement |> Placement.changeset(attrs) |> Repo.update()
  end

  @doc """
  Only a flyer that was never put up and never scanned can go. Anything else
  may be on a board with a working QR, so it's marked `removed` instead.
  """
  def delete_placement(%Placement{status: "planned", scans_count: 0} = placement),
    do: Repo.delete(placement)

  def delete_placement(%Placement{}), do: {:error, :printed}

  @doc """
  One sourcing search's results that aren't flyer placements yet — the supply
  houses it found, ready to be added.

  Always scoped to a single search: a project's searches mix the venues you'd
  put a flyer up in with the contractors you're selling to, and offering them
  together is how a roofer ends up on the flyer list.
  """
  def candidate_orgs(project_id, source_id, opts \\ [])

  def candidate_orgs(_project_id, nil, _opts), do: []

  def candidate_orgs(project_id, source_id, opts) do
    placed = from(p in Placement, where: not is_nil(p.org_id), select: p.org_id)

    Org
    |> join(:inner, [o], s in Source, on: s.id == o.source_id)
    |> where([_o, s], s.project_id == ^project_id and s.id == ^source_id)
    |> where([_o, s], s.purpose == "flyers")
    |> where([o], o.id not in subquery(placed))
    |> where([o], o.status != "rejected")
    |> order_by([o], asc: o.city, asc: o.name, asc: o.inserted_at)
    |> Repo.all()
    # Google lists some stores twice under two ids. Offering both is how two
    # flyers ended up on one board, so a place already on the list, or a
    # second listing of one above it, isn't offered.
    |> reject_placed(placed_keys(project_id))
    |> Enum.uniq_by(&place_key(org_place(&1)))
    |> Enum.take(Keyword.get(opts, :limit, 300))
  end

  defp reject_placed(orgs, keys), do: Enum.reject(orgs, &(place_key(org_place(&1)) in keys))

  defp placed_keys(project_id) do
    from(p in Placement, where: p.project_id == ^project_id, select: {p.venue_name, p.address})
    |> Repo.all()
    |> MapSet.new(fn {name, address} ->
      place_key(%{"venue_name" => name, "address" => address})
    end)
  end

  # Matches the unique index: name and address, ignoring case and the spaces
  # at either end.
  defp place_key(attrs) do
    {attrs["venue_name"] |> to_string() |> String.trim() |> String.downcase(),
     attrs["address"] |> to_string() |> String.trim() |> String.downcase()}
  end

  @doc """
  Adds the given sourcing results as placements, if they belong to this
  project and aren't placed already. Returns how many were added.
  """
  def add_orgs(%Project{} = project, org_ids) when is_list(org_ids) do
    placed = from(p in Placement, where: not is_nil(p.org_id), select: p.org_id)

    Org
    |> join(:inner, [o], s in Source, on: s.id == o.source_id)
    |> where([o, s], s.project_id == ^project.id and o.id in ^org_ids)
    |> where([_o, s], s.purpose == "flyers")
    |> where([o], o.id not in subquery(placed))
    |> Repo.all()
    |> Enum.reduce(0, fn org, added ->
      case create_placement(project, org_attrs(org), org_id: org.id) do
        {:ok, _placement} -> added + 1
        {:error, _changeset} -> added
      end
    end)
  end

  defp org_attrs(%Org{} = org) do
    org
    |> org_place()
    |> Map.merge(%{"phone" => org.phone, "code" => unique_code(org.name, org_town(org))})
  end

  defp org_place(%Org{} = org) do
    %{
      "venue_name" => org.name,
      "address" => [org.street, org_town(org)] |> Enum.reject(&blank?/1) |> Enum.join(", ")
    }
  end

  defp org_town(%Org{} = org),
    do: [org.city, org.region] |> Enum.reject(&blank?/1) |> Enum.join(", ")

  ## Scans

  @doc """
  Counts a scan and returns the placement, or `:error` for an unknown code.

  A `removed` flyer still redirects — someone is standing there holding a phone —
  but isn't counted, since the board it was on is no longer one we're working.
  """
  def record_scan(code, user_agent \\ nil) when is_binary(code) do
    case Repo.get_by(Placement, code: String.downcase(code)) |> Repo.preload(:project) do
      nil ->
        :error

      %Placement{status: "removed"} = placement ->
        {:ok, placement}

      placement ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          Repo.insert!(%Scan{
            placement_id: placement.id,
            user_agent: user_agent && String.slice(user_agent, 0, 500)
          })

          {1, _} =
            Placement
            |> where([p], p.id == ^placement.id)
            |> Repo.update_all(inc: [scans_count: 1], set: [last_scanned_at: now])

          %{placement | scans_count: placement.scans_count + 1, last_scanned_at: now}
        end)
    end
  end

  @doc """
  Where a scan goes: the flyer's URL with `?s=<code>` (and `&t=<trade>`),
  keeping any query the URL already had. The landing page can count and tailor
  on those too.
  """
  def destination_url(%Placement{project: %Project{} = project} = placement) do
    uri = URI.parse(content(project).url || "")

    params =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("s", placement.code)
      |> then(fn q ->
        if blank?(placement.trade), do: q, else: Map.put(q, "t", placement.trade)
      end)

    URI.to_string(%{uri | query: URI.encode_query(params)})
  end

  @doc "The URL the QR encodes: our own redirect, so the scan is counted first."
  def scan_url(%Placement{code: code}), do: ColdForgeWeb.Endpoint.url() <> "/f/" <> code

  @doc "The QR code as inline SVG, at error-correction level H — flyers get rained on."
  def qr_svg(%Placement{} = placement) do
    placement
    |> scan_url()
    |> EQRCode.encode(:h)
    |> EQRCode.svg(viewbox: true)
    # Inlined into an HTML page, where an XML prolog is invalid.
    |> String.replace(~r/<\?xml[^>]*\?>/, "")
    |> String.replace("<svg ", ~s(<svg class="qr" ), global: false)
  end

  ## Codes

  @doc """
  A code made from a name and town, unique across all flyers:
  `"ABC Supply", "Wyoming, MI"` → `abc-supply-wyoming`, then `-2`, `-3`.
  """
  def unique_code(name, town) do
    base =
      [name, town_of(town)]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> slugify()
      |> String.slice(0, 54)
      |> String.trim("-")
      |> case do
        "" -> "flyer"
        slug -> slug
      end

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(fn code -> not Repo.exists?(from p in Placement, where: p.code == ^code) end)
  end

  # The town from whatever was typed: "Wyoming, MI" and
  # "2950 Prairie St SW, Wyoming, MI 49509" are both Wyoming — the part before
  # the state, not the street.
  defp town_of(address) do
    parts =
      address
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.reverse(parts) do
      [last, town | _] ->
        if Regex.match?(~r/^[A-Za-z]{2}(\s+\d{5}(-\d{4})?)?$/, last), do: town, else: hd(parts)

      [only] ->
        only

      [] ->
        nil
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")
end
