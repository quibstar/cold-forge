defmodule ColdForge.Repo.Migrations.FillInPlacesAddresses do
  use Ecto.Migration

  import Ecto.Query

  # Google Places results kept the one-line address in `raw` and left street,
  # city, region and postal code empty, so the flyer list couldn't say which
  # ABC Supply was which, or sort by town. Search results split it now; this
  # splits the ones already found.
  def up do
    rows =
      repo().all(
        from(o in "sourcing_orgs",
          where: o.provider == "places" and is_nil(o.city),
          where: not is_nil(fragment("?->>'formatted_address'", o.raw)),
          select: {o.id, fragment("?->>'formatted_address'", o.raw)}
        )
      )

    for {id, address} <- rows,
        %{city: city} = parts = ColdForge.Sourcing.Discovery.Places.split_address(address),
        not is_nil(city) do
      repo().update_all(from(o in "sourcing_orgs", where: o.id == ^id),
        set: [
          street: parts.street,
          city: parts.city,
          region: parts.region,
          postal_code: parts.postal_code
        ]
      )
    end
  end

  # Nothing to undo: the address is still in `raw`.
  def down, do: :ok
end
