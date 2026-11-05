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
  """
  def print(conn, %{"project_id" => project_id} = params) do
    project = Outreach.get_project!(project_id)
    content = Flyers.content(project)
    side = if params["side"] in ["front", "back"], do: params["side"], else: "both"

    cards =
      project.id
      |> Postcards.get_postcards(ids(params))
      |> Enum.map(fn card ->
        %{
          card: card,
          qr: Postcards.qr_svg(card),
          note: Content.postcard_paragraphs(content, card.name)
        }
      end)

    conn
    |> put_root_layout(false)
    |> put_view(html: ColdForgeWeb.PostcardHTML)
    |> render(:print,
      layout: false,
      brand: ColdForgeWeb.FlyerHTML.brand(project),
      project: project,
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

  defp ids(params), do: params |> Map.get("ids", "") |> String.split(",", trim: true)
end
