defmodule ColdForgeWeb.FlyerController do
  @moduledoc """
  The two ends of a printed flyer: the sheet you print, and the scan that comes
  back from it.
  """
  use ColdForgeWeb, :controller

  alias ColdForge.{Flyers, Outreach}
  alias ColdForge.Flyers.{Content, Placement}

  @doc """
  A QR scan. Counts it against the counter the flyer stands on, then sends the
  person to the landing page with `?s=<code>`.

  An unknown code is a 404 rather than a guess at where to send them: it's
  either a typo or a flyer nobody printed.
  """
  def scan(conn, %{"code" => code}) do
    user_agent = conn |> get_req_header("user-agent") |> List.first()

    case Flyers.record_scan(code, user_agent) do
      {:ok, placement} ->
        redirect(conn, external: Flyers.destination_url(placement))

      :error ->
        conn |> put_status(:not_found) |> text("This flyer isn't active.")
    end
  end

  @doc """
  Letter sheets, one per selected placement, each with its own QR. Print at
  100% with headers and footers off — the page says so on screen.

  For a big run, two passes: `mode=shop` is one sheet for a print shop with
  the QR square empty, and `mode=overlay` is only each ticked place's QR and
  code, in that square, to run through your own printer onto the shop's
  sheets.
  """
  def print(conn, %{"project_id" => project_id} = params) do
    project = Outreach.get_project!(project_id)
    ids = params |> Map.get("ids", "") |> String.split(",", trim: true)
    content = Flyers.content(project)
    mode = if params["mode"] in ["shop", "overlay"], do: params["mode"], else: "full"

    sheets =
      if mode == "shop" do
        # One sheet for a print shop to run in quantity: the QR square left
        # empty, and the plain eyebrow, since it can't name each place's trade.
        [%{placement: %Placement{code: ""}, eyebrow: content.eyebrow, qr: ""}]
      else
        project.id
        |> Flyers.get_placements(ids)
        |> Enum.map(fn placement ->
          %{
            placement: placement,
            eyebrow: Content.eyebrow(content, placement.trade),
            qr: Flyers.qr_svg(placement)
          }
        end)
      end

    conn
    |> put_root_layout(false)
    |> put_view(html: ColdForgeWeb.FlyerHTML)
    |> render(:print,
      layout: false,
      brand: ColdForgeWeb.FlyerHTML.brand(project),
      mode: mode,
      content: content,
      sheets: sheets,
      steps: Content.steps(content),
      highlights: Content.highlights(content),
      preview?: params["preview"] in ["1", "true"],
      display_url: Content.display_url(content)
    )
  end
end
