defmodule ColdForgeWeb.PostcardController do
  @moduledoc """
  The ends of a mailed postcard: the cards you print, the list you hand a
  mailing service, and the scan that comes back.
  """
  use ColdForgeWeb, :controller

  alias ColdForge.{Flyers, Outreach, Postcards}
  alias ColdForge.Flyers.Content

  @doc """
  A QR scan. Counts it against the card — and so the prospect — then sends the
  person to the landing page. An unknown code is a 404, not a guess.
  """
  def scan(conn, %{"code" => code}) do
    user_agent = conn |> get_req_header("user-agent") |> List.first()

    case Postcards.record_scan(code, user_agent) do
      {:ok, card} ->
        redirect(conn, external: Postcards.destination_url(card))

      :error ->
        conn |> put_status(:not_found) |> text("This postcard isn't active.")
    end
  end

  @doc """
  6×9 cards, front then back for each. `side=front` prints the one front a
  mailing service needs; `side=back` just the addressed backs.

  Printing in bulk is two passes, and `mode` picks the pass:

    * `mode=shop` — one card for a print shop to run in quantity, the same for
      everyone: the QR, the greeting and the address left blank. Needs no ids.
    * `mode=overlay` — for each ticked card, only what the shop left blank, in
      exactly those places, to run through your own printer onto the printed
      cards.
    * `mode=stannp` — the artwork Stannp's print-and-mail service takes: one
      front and one back at 9.24 × 6.24 in (Stannp's 0.12 in bleed on every
      side). The back leaves Stannp's address box and the QR square empty;
      Stannp prints each recipient's address there, and a QR from the mailing
      list's QR URL column. Needs no ids.

  Both draw the same back — with the note's `{{company}}` made generic, since
  the shop prints one note for all — and hide the other pass's parts, so the
  two line up.
  """
  def print(conn, %{"project_id" => project_id} = params) do
    project = Outreach.get_project!(project_id)
    content = Flyers.content(project)
    brand = ColdForgeWeb.FlyerHTML.brand(project)

    mode =
      if params["mode"] in ["shop", "overlay", "stannp"], do: params["mode"], else: "full"

    side =
      cond do
        mode == "overlay" -> "back"
        params["side"] in ["front", "back"] -> params["side"]
        true -> "both"
      end

    note_for = fn name ->
      if mode == "full",
        do: Content.postcard_paragraphs(content, name),
        else: Content.postcard_paragraphs(content, brand.recipient)
    end

    cards =
      if mode in ["shop", "stannp"] do
        [%{card: blank_card(), qr: "", note: note_for.(nil)}]
      else
        project.id
        |> Postcards.get_postcards(ids(params))
        |> Enum.map(fn card ->
          %{card: card, qr: Postcards.qr_svg(card), note: note_for.(card.name)}
        end)
      end

    conn
    |> put_root_layout(false)
    |> put_view(html: ColdForgeWeb.PostcardHTML)
    |> render(:print,
      layout: false,
      brand: brand,
      project: project,
      mode: mode,
      content: content,
      cards: cards,
      side: side,
      highlights: Content.highlights(content),
      preview?: params["preview"] in ["1", "true"],
      display_url: Content.display_url(content)
    )
  end

  @doc "The selected cards as a CSV mailing list."
  def export(conn, %{"project_id" => project_id} = params) do
    project = Outreach.get_project!(project_id)
    cards = Postcards.get_postcards(project.id, ids(params))
    filename = "postcards-#{Date.utc_today()}.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, Postcards.to_csv(cards))
  end

  # The shop's card: nothing on it belongs to anyone.
  defp blank_card,
    do: %ColdForge.Postcards.Postcard{
      name: "",
      street: "",
      city: "",
      region: "",
      postal_code: "",
      code: ""
    }

  defp ids(params), do: params |> Map.get("ids", "") |> String.split(",", trim: true)
end
