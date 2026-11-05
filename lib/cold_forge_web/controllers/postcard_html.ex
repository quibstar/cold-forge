defmodule ColdForgeWeb.PostcardHTML do
  @moduledoc "The printable 6×9 postcard: the flyer's design, cut down to a card."
  use ColdForgeWeb, :html

  import ColdForgeWeb.FlyerHTML, only: [brand_lockup: 1, brand_css: 1]

  alias ColdForge.Postcards.Postcard

  embed_templates "postcard_html/*"

  @doc "The return address as lines, split at its commas after the name and street."
  def return_lines(nil), do: []

  def return_lines(address) do
    case address |> String.split(",") |> Enum.map(&String.trim/1) do
      [name, street | rest] when rest != [] -> [name, street, Enum.join(rest, ", ")]
      parts -> parts
    end
  end

  def city_line(%Postcard{} = card), do: Postcard.city_line(card)
end
