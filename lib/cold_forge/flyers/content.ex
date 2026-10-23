defmodule ColdForge.Flyers.Content do
  @moduledoc """
  What a project's printed flyer says. One per project, stored on it.

  The headline should match, word for word, the page the QR lands on: somebody
  who scans a flyer and lands on different words reads it as the wrong page.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Where a scan ends up, after the scan is counted. Shown on the flyer too,
    # without the scheme, for people who'd rather type it.
    field :url, :string
    field :eyebrow, :string
    # Used instead of `eyebrow` when a placement names a trade; `{{trade}}` is
    # replaced with it ("For {{trade}} contractors").
    field :trade_eyebrow, :string
    field :headline, :string
    field :lede, :string
    # One per line. "Bold part — the rest" bolds the part before the dash.
    field :steps, :string
    # One per line, printed as badges under the steps: the short claims that
    # aren't a step in the job — "Offline mobile app".
    field :highlights, :string
    field :closing, :string
    field :terms, :string
    field :footer, :string
  end

  @fields ~w(url eyebrow trade_eyebrow headline lede steps highlights closing terms footer)a

  def changeset(content, attrs) do
    content
    |> cast(attrs, @fields)
    |> validate_required([:url, :headline])
    |> validate_change(:url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          []

        _ ->
          [url: "must be a full URL starting with http:// or https://"]
      end
    end)
  end

  @doc "The URL as printed: no scheme, no trailing slash."
  def display_url(%__MODULE__{url: url}) when is_binary(url) do
    url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
  end

  def display_url(_content), do: ""

  @doc "The eyebrow for a placement's trade, or the plain one."
  def eyebrow(%__MODULE__{} = content, trade) when is_binary(trade) and trade != "" do
    case content.trade_eyebrow do
      template when is_binary(template) and template != "" ->
        String.replace(template, "{{trade}}", trade)

      _ ->
        content.eyebrow
    end
  end

  def eyebrow(%__MODULE__{eyebrow: eyebrow}, _trade), do: eyebrow

  @doc """
  The steps as `{bold, rest}` pairs. A line with no " — " is all rest, so a
  plain sentence still prints.
  """
  def steps(%__MODULE__{steps: steps}) when is_binary(steps) do
    steps
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, " — ", parts: 2) do
        [bold, rest] -> {bold, " — " <> rest}
        [plain] -> {nil, plain}
      end
    end)
  end

  def steps(_content), do: []

  @doc "The highlights, one per line, blanks dropped."
  def highlights(%__MODULE__{highlights: highlights}) when is_binary(highlights) do
    highlights
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def highlights(_content), do: []

  @doc "The headline's lines, so a deliberate line break survives printing."
  def headline_lines(%__MODULE__{headline: headline}) when is_binary(headline),
    do: headline |> String.split(["\r\n", "\n"], trim: true) |> Enum.map(&String.trim/1)

  def headline_lines(_content), do: []
end
