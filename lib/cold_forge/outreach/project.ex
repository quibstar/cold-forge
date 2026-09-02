defmodule ColdForge.Outreach.Project do
  @moduledoc """
  One idea/product. Owns its sender identity and its landing page, so ExteriorPro
  outreach never picks up another project's from-address or unsubscribe copy.
  """
  use ColdForge.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :from_name, :string
    field :from_email, :string
    field :reply_to, :string
    field :landing_url, :string
    field :postal_address, :string
    field :industry, :string
    field :signature, :string
    field :logo_url, :string
    field :logo_path, :string
    field :brand_color, :string
    field :timezone, :string, default: "America/New_York"
    field :active, :boolean, default: true

    has_many :prospects, ColdForge.Outreach.Prospect
    has_many :campaigns, ColdForge.Outreach.Campaign

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :slug,
      :from_name,
      :from_email,
      :reply_to,
      :landing_url,
      :postal_address,
      :industry,
      :signature,
      :logo_url,
      :logo_path,
      :brand_color,
      :timezone,
      :active
    ])
    |> validate_required([:name, :from_name, :from_email])
    |> maybe_generate_slug()
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "may only contain lowercase letters, numbers and dashes"
    )
    |> validate_format(:from_email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email"
    )
    |> validate_url(:landing_url)
    |> validate_optional_url(:logo_url)
    |> validate_format(:brand_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a hex colour like #0f766e"
    )
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        name = get_field(changeset, :name)
        if name, do: put_change(changeset, :slug, slugify(name)), else: changeset

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Absolute URL for the project's logo, or `nil`.

  An uploaded file wins over a typed URL — if you took the trouble to upload
  one, that's the one you meant. The result is always absolute: a mail client
  fetches it from the open internet with no page to resolve a relative path
  against.
  """
  def logo_src(%__MODULE__{} = project, base_url) do
    cond do
      project.logo_path not in [nil, ""] -> base_url <> project.logo_path
      project.logo_url not in [nil, ""] -> project.logo_url
      true -> nil
    end
  end

  # A logo referenced by a relative path would resolve against the recipient's
  # mail client, not our site — it has to be absolute or it's a broken image.
  defp validate_optional_url(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      "" -> changeset
      _ -> validate_url(changeset, field)
    end
  end

  # A landing URL that isn't absolute would redirect back into Cold Forge
  # instead of out to the project's site.
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          []

        _ ->
          [{field, "must be a full URL starting with http:// or https://"}]
      end
    end)
  end
end
