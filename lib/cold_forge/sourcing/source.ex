defmodule ColdForge.Sourcing.Source do
  @moduledoc """
  A saved search: what to look for, where, and which project its prospects
  belong to.

  One per thing you are selling — "ExteriorPro, West Michigan" — rather than
  one per query, because the trades and the towns are the parameters of a
  single ongoing effort and are worth keeping together. Running it again later
  picks up whatever opened since.

  The project is set here, once, instead of being chosen row by row when
  promoting. You know which project a search is for when you set it up; being
  asked again three hundred rows later is just a chance to get it wrong.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  alias ColdForge.Sourcing.Discovery.{Overpass, Places}
  alias ColdForge.Sourcing.Towns

  # Google's published list price for a Text Search that asks for a website or
  # phone number (the Enterprise SKU), per 1,000 requests. Only used to put a
  # rough figure in front of a run before it starts, so a typo or a whole
  # state is visible as money rather than discovered on the bill. Check the
  # Cloud console for the rate actually being charged.
  @usd_per_1000_requests 35

  @providers ~w(places overpass)

  schema "sourcing_sources" do
    field :name, :string
    field :provider, :string, default: "places"
    field :segments, {:array, :string}, default: []
    # Typed as a comma-separated list, which is quicker than hunting through
    # eight checkboxes and reads back as a sentence.
    field :segments_text, :string, virtual: true
    field :localities, {:array, :string}, default: []
    # Form-only: the operator types one town per line, which is far easier to
    # edit than a comma-separated string, and it survives a failed validation.
    field :localities_text, :string, virtual: true
    field :active, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :last_run_summary, :map, default: %{}
    field :notes, :string

    belongs_to :project, ColdForge.Outreach.Project
    has_many :orgs, ColdForge.Sourcing.Org, foreign_key: :source_id

    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers

  @doc "The segments a provider can search for."
  def segments_for("places"), do: Enum.sort(Places.segments())
  def segments_for("overpass"), do: Enum.sort(Overpass.segments())
  def segments_for(_provider), do: []

  @doc """
  A filled-in example for the field's placeholder.

  Separate from `locality_hint/1`: repeating the hint inside the box it is
  already printed under says the same thing twice and shows nothing.
  """
  def locality_example("places"), do: "Michigan\nToledo, OH\nSouth Bend, IN"
  def locality_example("overpass"), do: "US-MI\nUS-OH"
  def locality_example(_provider), do: ""

  @doc "What a locality looks like for this provider, for the form's hint."
  def locality_hint("places"),
    do: ~s(One per line: a town like "Grand Rapids, MI", or a whole state like "Michigan")

  def locality_hint("overpass"), do: ~s(One per line, as state codes like "US-MI")
  def locality_hint(_provider), do: "One per line"

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :project_id,
      :provider,
      :segments,
      :segments_text,
      :localities,
      :localities_text,
      :active,
      :notes
    ])
    |> parse_segments()
    |> parse_localities()
    |> validate_required([:name, :project_id, :provider])
    |> validate_inclusion(:provider, @providers)
    # Not validate_length/3: it only runs when the field changed, and an
    # untouched set of checkboxes sends no `segments` key at all — so an empty
    # source would save silently.
    |> validate_not_empty(:segments, :segments_text, "name at least one thing to look for")
    # The error goes on the virtual field, because that is the one with an
    # input next to it — an error on `localities` renders nowhere.
    |> validate_not_empty(:localities, :localities_text, "add at least one place to search")
    |> validate_segments_known()
    |> validate_states_known()
    |> unique_constraint(:name, message: "there is already a source with that name")
    |> foreign_key_constraint(:project_id)
  end

  # The textarea is the source of truth when it was edited, so what the
  # operator typed survives a validation error instead of snapping back.
  defp parse_localities(changeset) do
    case get_change(changeset, :localities_text) do
      nil ->
        changeset

      text ->
        localities =
          text
          |> String.split(["\n", "\r\n"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :localities, localities)
    end
  end

  # "Roofing, Gutters, Humane Society" is what somebody types; "roofing",
  # "gutters", "humane_society" is what the providers are keyed on. Normalising
  # here lets the field be written the natural way.
  #
  # For Google Places anything goes: Places searches free text, so a trade it
  # has no tuned phrases for is searched exactly as typed, and everyday wording
  # for a built-in one ("Windows & Doors") lands on the built-in. OpenStreetMap
  # can only search the tags it has, so it still takes its fixed list.
  defp parse_segments(changeset) do
    case get_change(changeset, :segments_text) do
      nil ->
        changeset

      text ->
        normalize =
          case get_field(changeset, :provider) do
            "overpass" -> &normalize_segment/1
            _places -> &Places.canonical/1
          end

        segments =
          text
          |> String.split(",")
          |> Enum.map(normalize)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :segments, segments)
    end
  end

  defp normalize_segment(term) do
    term
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s\-]+/, "_")
  end

  @doc "A source's segments as the comma-separated text the field shows."
  def segments_text(%__MODULE__{segments: segments}) when is_list(segments),
    do: Enum.map_join(segments, ", ", &String.replace(&1, "_", " "))

  def segments_text(_source), do: ""

  defp validate_not_empty(changeset, field, error_field, message) do
    case get_field(changeset, field) do
      list when is_list(list) and list != [] -> changeset
      _ -> add_error(changeset, error_field, message)
    end
  end

  # Only OpenStreetMap has a fixed vocabulary; Places takes anything.
  defp validate_segments_known(changeset) do
    case get_field(changeset, :provider) do
      "overpass" -> validate_segments_in(changeset, "overpass")
      _places -> changeset
    end
  end

  defp validate_segments_in(changeset, provider) do
    known = segments_for(provider)

    case Enum.reject(get_field(changeset, :segments) || [], &(&1 in known)) do
      [] ->
        changeset

      unknown ->
        add_error(
          changeset,
          :segments_text,
          "#{provider} can't search for #{Enum.join(unknown, ", ")}. It knows: " <>
            Enum.map_join(known, ", ", &String.replace(&1, "_", " "))
        )
    end
  end

  # A two-letter code that isn't a state is almost certainly a typo for one,
  # and searching "roofing contractor in MX" is a billed search for nothing.
  defp validate_states_known(changeset) do
    case get_field(changeset, :provider) do
      "overpass" ->
        changeset

      _places ->
        bad =
          (get_field(changeset, :localities) || [])
          |> Enum.filter(&(String.match?(&1, ~r/^[A-Za-z]{2}$/) and is_nil(Towns.state_code(&1))))

        case bad do
          [] -> changeset
          _ -> add_error(changeset, :localities_text, "#{Enum.join(bad, ", ")} isn't a state")
        end
    end
  end

  @doc "The textarea's starting value, for an existing source."
  def localities_text(%__MODULE__{localities: localities}) when is_list(localities),
    do: Enum.join(localities, "\n")

  def localities_text(_source), do: ""

  @doc """
  Every search this source will run, as `{segment, phrase, locality}`.

  Places caps a text search at 60 results, so coverage comes from many narrow
  queries rather than one broad one: one per phrase per town. A state in
  "Where" becomes its towns here, at run time, so a search saved as "Michigan"
  stays one readable line and still covers the state.

  OpenStreetMap queries a whole region at once and has no phrases, so its
  entries carry `nil` for the phrase and the locality as written.
  """
  def queries(%__MODULE__{provider: "overpass", segments: segments, localities: localities}) do
    for segment <- segments, locality <- localities, do: {segment, nil, locality}
  end

  def queries(%__MODULE__{segments: segments, localities: localities}) do
    towns = places_towns(localities)

    for segment <- segments,
        phrase <- Places.queries_for(segment),
        town <- towns,
        do: {segment, phrase, town}
  end

  defp places_towns(localities) do
    localities |> Enum.flat_map(&Towns.expand/1) |> Enum.uniq()
  end

  @doc """
  What running this source will do, before it does it: the phrases per trade,
  how many towns a state became, and the request count and rough cost.

  Each search is at least one request and at most three — Places pages 20 at a
  time up to 60 — so both ends are given. Small towns mostly stop at one page.
  """
  def plan(%__MODULE__{provider: "overpass"} = source) do
    searches = length(queries(source))

    %{
      trades: Enum.map(source.segments, &{&1, []}),
      states: [],
      towns: length(source.localities),
      searches: searches,
      min_requests: searches,
      max_requests: searches,
      min_cost: 0,
      max_cost: 0
    }
  end

  def plan(%__MODULE__{} = source) do
    searches = length(queries(source))

    states =
      for locality <- source.localities,
          code = Towns.state_code(locality),
          code != nil,
          do: {Towns.state_name(code), length(Towns.towns(code))}

    %{
      trades: Enum.map(source.segments, &{&1, Places.queries_for(&1)}),
      states: states,
      towns: length(places_towns(source.localities)),
      searches: searches,
      min_requests: searches,
      max_requests: searches * 3,
      min_cost: cost(searches),
      max_cost: cost(searches * 3)
    }
  end

  defp cost(requests), do: Float.round(requests * @usd_per_1000_requests / 1000, 2)
end
