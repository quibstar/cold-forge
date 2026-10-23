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

  @doc "A teal disc with a white tick: one per step."
  attr :class, :string, default: nil

  def check(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="12" fill="#0F766E" />
      <path
        d="M6.8 12.4l3.4 3.4 7-7.2"
        fill="none"
        stroke="#fff"
        stroke-width="2.6"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc """
  The project's callback number as people write it: `"6164015969"` →
  `"(616) 401-5969"`. Anything that isn't ten US digits prints as entered.
  """
  def phone(nil), do: nil

  def phone(number) do
    case String.replace(number, ~r/\D/, "") |> String.replace_prefix("1", "") do
      <<a::binary-3, b::binary-3, c::binary-4>> -> "(#{a}) #{b}-#{c}"
      _ -> String.trim(number) |> then(&if(&1 == "", do: nil, else: &1))
    end
  end

  @doc "A step's detail without the dash that joined it to its bold part."
  def step_detail(rest), do: rest |> to_string() |> String.replace_prefix(" — ", "")
end
