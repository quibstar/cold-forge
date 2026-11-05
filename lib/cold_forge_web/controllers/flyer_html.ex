defmodule ColdForgeWeb.FlyerHTML do
  @moduledoc "The printable flyer sheet."
  use ColdForgeWeb, :html

  embed_templates "flyer_html/*"

  # ExteriorPro's E: three bars, 45° cut on the right, from the brand kit
  # (Sales & Marketing/brand).
  @mark "M8 9 H41 L32.5 17.5 H8 A1 1 0 0 1 7 16.5 V10 A1 1 0 0 1 8 9 Z M8 19.75 H35.5 L27 28.25 H8 A1 1 0 0 1 7 27.25 V20.75 A1 1 0 0 1 8 19.75 Z M8 30.5 H30 L21.5 39 H8 A1 1 0 0 1 7 38 V31.5 A1 1 0 0 1 8 30.5 Z"

  @doc """
  The horizontal lockup — mark plus "ExteriorPro" — as the brand kit's
  `exteriorpro-lockup-light.svg` draws it. Inline rather than an image so it
  prints sharp at any size and its wordmark uses the page's Instrument Sans.
  """
  attr :class, :string, default: nil

  def lockup(assigns) do
    assigns = assign(assigns, :mark, @mark)

    ~H"""
    <svg class={@class} viewBox="0 0 392 72" role="img" aria-label="ExteriorPro">
      <defs>
        <linearGradient
          id="ep-ramp"
          gradientUnits="userSpaceOnUse"
          x1="6"
          y1="66"
          x2="74"
          y2="6"
        >
          <stop offset="0" stop-color="#0F766E" />
          <stop offset="0.55" stop-color="#14B8A6" />
          <stop offset="1" stop-color="#2DD4BF" />
        </linearGradient>
      </defs>
      <g transform="translate(6 6) scale(2) translate(-7 -9)">
        <path fill="url(#ep-ramp)" d={@mark} />
      </g>
      <text
        x="92"
        y="49"
        font-family="'Instrument Sans','Helvetica Neue',Helvetica,Arial,sans-serif"
        font-size="46"
        font-weight="600"
        letter-spacing="-2"
        fill="#0F172A"
      >
        Exterior<tspan fill="#14B8A6">Pro</tspan>
      </text>
    </svg>
    """
  end

  @brands %{
    "exteriorpro" => %{
      logo: :exteriorpro,
      photo: "/images/flyers/exteriorpro-avatar.webp",
      photo_alt: "An ExteriorPro rep with a tablet outside a finished home",
      photo_position: "50% 18%",
      back_greeting: "For the crew at",
      # Who `{{company}}` becomes on a card printed the same for everyone.
      recipient: "your company",
      # Deep teal for anything printed on white: primary teal washes out on
      # toner. Light teal only on the dark band, where the kit says to use it.
      colors: %{
        accent_text: "#0F766E",
        band_bg: "#0F766E",
        band_fg: "#FFFFFF",
        accent_on_dark: "#5EEAD4",
        check_bg: "#0F766E",
        check_fg: "#FFFFFF"
      }
    },
    "furizzma" => %{
      logo: {"/images/flyers/furizzma-logo.png", "Furizzma"},
      photo: "/images/flyers/furizzma-photo.webp",
      photo_alt: "A woman reading on the sofa with her Shiba Inu",
      photo_position: "40% 50%",
      back_greeting: "For everyone at",
      recipient: "your rescue",
      # Furizzma's yellow is a fill, never text on white — it disappears.
      # Text takes the dark amber; the yellow carries ink on top of it.
      colors: %{
        accent_text: "#A16207",
        band_bg: "#EAB308",
        band_fg: "#0F172A",
        accent_on_dark: "#FACC15",
        check_bg: "#EAB308",
        check_fg: "#0F172A"
      }
    }
  }

  @doc """
  How a project's printed pieces look: its logo, the photo, the greeting on a
  postcard's back, and its colours as CSS custom properties. A project with no
  brand of its own prints as ExteriorPro, which is where the design came from.
  """
  def brand(%{slug: slug}), do: Map.get(@brands, slug, @brands["exteriorpro"])
  def brand(_project), do: @brands["exteriorpro"]

  @doc "The brand's colours as a `:root` rule, for a print page's stylesheet."
  def brand_css(%{colors: colors}) do
    vars =
      Enum.map_join(colors, " ", fn {name, value} ->
        "--#{name |> to_string() |> String.replace("_", "-")}: #{value};"
      end)

    ":root { #{vars} }"
  end

  @doc """
  The brand's logo: ExteriorPro's drawn lockup, or a mark image beside the
  name set in the page's face.
  """
  attr :brand, :map, required: true
  attr :class, :string, default: nil

  def brand_lockup(%{brand: %{logo: :exteriorpro}} = assigns) do
    ~H"""
    <.lockup class={@class} />
    """
  end

  def brand_lockup(%{brand: %{logo: {src, name}}} = assigns) do
    assigns = assign(assigns, src: src, name: name)

    ~H"""
    <span class={["brand-lockup", @class]} role="img" aria-label={@name}>
      <img src={@src} alt="" />
      <span>{@name}</span>
    </span>
    """
  end

  @doc "A disc in the brand's colour with a tick: one per step."
  attr :class, :string, default: nil

  def check(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="12" style="fill: var(--check-bg, #0F766E)" />
      <path
        d="M6.8 12.4l3.4 3.4 7-7.2"
        fill="none"
        style="stroke: var(--check-fg, #fff)"
        stroke-width="2.6"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc "A step's detail without the dash that joined it to its bold part."
  def step_detail(rest), do: rest |> to_string() |> String.replace_prefix(" — ", "")
end
