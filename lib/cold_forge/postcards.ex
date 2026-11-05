defmodule ColdForge.Postcards do
  @moduledoc """
  Postcards mailed to prospects, one each, every one with its own QR code.

  A flyer on a supply-house counter can only say which counter produced a scan.
  A postcard says which prospect did, so a scan is somebody worth calling that
  week. The words come from the project's flyer — the same landing page,
  headline and highlights — plus a short note for the back.

  Recipients are prospects whose sourcing record has a full street address.
  Prospects imported from a list usually don't, and aren't offered.
  """
  import Ecto.Query, warn: false

  alias ColdForge.{Flyers, Outreach, Repo}
  alias ColdForge.Outreach.{Project, Prospect}
  alias ColdForge.Postcards.{Postcard, Scan}
  alias ColdForge.Sourcing.Org

  ## Cards

  def list_postcards(project_id) do
    Postcard
    |> where([c], c.project_id == ^project_id)
    |> order_by([c], desc: c.scans_count, asc: c.city, asc: c.name)
    |> Repo.all()
  end

  def get_postcards(project_id, ids) when is_list(ids) do
    Postcard
    |> where([c], c.project_id == ^project_id and c.id in ^ids)
    |> order_by([c], asc: c.postal_code, asc: c.name)
    |> Repo.all()
  end

  def get_postcard!(id), do: Repo.get!(Postcard, id)

  @doc """
  Marks cards as mailed, today. Only planned cards move: a returned card stays
  returned.
  """
  def mark_mailed(project_id, ids) when is_list(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Postcard
      |> where([c], c.project_id == ^project_id and c.id in ^ids and c.status == "planned")
      |> Repo.update_all(set: [status: "mailed", mailed_at: now, updated_at: now])

    count
  end

  def set_status(%Postcard{} = card, status) do
    card |> Postcard.changeset(%{status: status}) |> Repo.update()
  end

  @doc """
  Only a card that was never mailed can go. Anything else may be on someone's
  desk with a working QR.
  """
  def delete_postcard(%Postcard{status: "planned", scans_count: 0} = card), do: Repo.delete(card)
  def delete_postcard(%Postcard{}), do: {:error, :mailed}

  ## Who can get one

  @doc """
  Prospects a postcard could go to, as `{prospect, org}` pairs, one per company
  address. Leaves out anyone with a card already, anyone who unsubscribed or
  has replied, and anyone without a full street address.

  Filters: `:trade` (a key from `Outreach.list_trades/1`), `:reach` —
  `"phone"` for prospects with no email address, `"email"` for those with one —
  and `:city`, matched loosely.
  """
  def candidates(project_id, filters \\ %{}) do
    carded = from(c in Postcard, where: c.project_id == ^project_id, select: c.prospect_id)

    Prospect
    |> join(:inner, [p], o in Org, on: o.prospect_id == p.id)
    |> where([p], p.project_id == ^project_id)
    |> where([p], p.status not in ["unsubscribed", "replied"])
    |> where([p], p.id not in subquery(carded))
    |> where([_p, o], not is_nil(o.street) and o.street != "")
    |> where([_p, o], not is_nil(o.city) and o.city != "")
    |> where([_p, o], not is_nil(o.region) and o.region != "")
    |> where([_p, o], not is_nil(o.postal_code) and o.postal_code != "")
    |> Outreach.filter_by_trade(project_id, filters[:trade])
    |> filter_reach(filters[:reach])
    |> filter_city(filters[:city])
    |> order_by([_p, o], asc: o.city, asc: o.name)
    |> select([p, o], {p, o})
    |> Repo.all()
    # A prospect can be linked from two search results, and a company can be
    # two prospects. One card per company address either way.
    |> Enum.uniq_by(fn {p, _o} -> p.id end)
    |> Enum.uniq_by(fn {p, o} -> {normalize(p.company || o.name), normalize(o.street)} end)
    |> reject_do_not_contact(project_id)
  end

  defp reject_do_not_contact(pairs, project_id) do
    case ColdForge.DoNotContact.list(project_id) do
      [] ->
        pairs

      entries ->
        Enum.reject(pairs, fn {p, _o} -> ColdForge.DoNotContact.match_entries(entries, p) end)
    end
  end

  defp filter_reach(query, "phone"), do: where(query, [p], is_nil(p.email) or p.email == "")
  defp filter_reach(query, "email"), do: where(query, [p], not is_nil(p.email) and p.email != "")
  defp filter_reach(query, _reach), do: query

  defp filter_city(query, city) when is_binary(city) and city != "" do
    where(query, [_p, o], ilike(o.city, ^"%#{String.trim(city)}%"))
  end

  defp filter_city(query, _city), do: query

  @doc """
  Adds a card for each `{prospect, org}` pair. Returns how many were added — a
  pair that gained a card since it was listed is skipped, not an error.
  """
  def add_cards(%Project{} = project, pairs) when is_list(pairs) do
    Enum.reduce(pairs, 0, fn {prospect, org}, added ->
      attrs = %{
        code: unique_code(prospect.company || org.name, org.city),
        name: prospect.company || org.name,
        street: org.street,
        city: org.city,
        region: org.region,
        postal_code: org.postal_code,
        trade: trade(prospect)
      }

      %Postcard{project_id: project.id, prospect_id: prospect.id}
      |> Postcard.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _card} -> added + 1
        {:error, _changeset} -> added
      end
    end)
  end

  defp trade(%Prospect{industry: industry}) when is_binary(industry) and industry != "",
    do: industry |> ColdForge.Sourcing.Discovery.Places.canonical() |> String.replace("_", " ")

  defp trade(_prospect), do: nil

  ## Scans

  @doc """
  Counts a scan and returns the card, or `:error` for an unknown code. A
  returned card still redirects — someone is holding it — but isn't counted.
  """
  def record_scan(code, user_agent \\ nil) when is_binary(code) do
    case Repo.get_by(Postcard, code: String.downcase(code)) |> Repo.preload(:project) do
      nil ->
        :error

      %Postcard{status: "returned"} = card ->
        {:ok, card}

      card ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          Repo.insert!(%Scan{
            postcard_id: card.id,
            user_agent: user_agent && String.slice(user_agent, 0, 500)
          })

          {1, _} =
            Postcard
            |> where([c], c.id == ^card.id)
            |> Repo.update_all(inc: [scans_count: 1], set: [last_scanned_at: now])

          %{card | scans_count: card.scans_count + 1, last_scanned_at: now}
        end)
    end
  end

  @doc """
  Where a scan goes: the flyer's landing page with `?s=<code>`, `&t=<trade>`
  and `&via=mail`, keeping any query the URL already had.
  """
  def destination_url(%Postcard{project: %Project{} = project} = card) do
    uri = URI.parse(Flyers.content(project).url || "")

    params =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("s", card.code)
      |> Map.put("via", "mail")
      |> then(fn q -> if card.trade in [nil, ""], do: q, else: Map.put(q, "t", card.trade) end)

    URI.to_string(%{uri | query: URI.encode_query(params)})
  end

  @doc "The URL the QR encodes: our own redirect, so the scan is counted first."
  def scan_url(%Postcard{code: code}), do: ColdForgeWeb.Endpoint.url() <> "/m/" <> code

  @doc "The QR code as inline SVG, at error-correction level H."
  def qr_svg(%Postcard{} = card) do
    card
    |> scan_url()
    |> EQRCode.encode(:h)
    |> EQRCode.svg(viewbox: true)
    |> String.replace(~r/<\?xml[^>]*\?>/, "")
    |> String.replace("<svg ", ~s(<svg class="qr" ), global: false)
  end

  ## Mailing list

  @doc """
  The cards as CSV for a print-and-mail service: one row per card, with the
  URL its QR should encode for services that print their own codes.
  """
  def to_csv(cards) when is_list(cards) do
    header = ["Organization", "Address", "City", "State", "Zip", "Code", "QR URL"]

    rows =
      Enum.map(cards, fn card ->
        [
          card.name,
          card.street,
          card.city,
          card.region,
          card.postal_code,
          card.code,
          scan_url(card)
        ]
      end)

    [header | rows]
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_field/1) end)
    |> Kernel.<>("\r\n")
  end

  defp csv_field(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: ~s("#{String.replace(value, "\"", "\"\"")}"),
      else: value
  end

  ## Codes

  @doc """
  A code from the company and town, unique across all cards:
  `"Herbert Roofing", "Grand Rapids"` → `herbert-roofing-grand-rapids`, then
  `-2`, `-3`.
  """
  def unique_code(name, town) do
    base =
      [name, town]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9\s-]/u, "")
      |> String.replace(~r/[\s-]+/, "-")
      |> String.slice(0, 54)
      |> String.trim("-")
      |> case do
        "" -> "card"
        slug -> slug
      end

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(fn code -> not Repo.exists?(from c in Postcard, where: c.code == ^code) end)
  end

  defp normalize(value),
    do: value |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
