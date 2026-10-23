defmodule ColdForge.Repo.Migrations.UniqueFlyerPlacements do
  use Ecto.Migration

  # One flyer per place. Google lists some stores twice under two ids — the
  # same name at the same address — and adding both put two flyers on one
  # board. Names and addresses are compared ignoring case and spacing at the
  # ends, the way a person reading the list would.
  #
  # The copies are removed first, keeping the one with the most scans, then
  # the oldest. A copy that was scanned is never deleted: if one is, the index
  # below refuses to build and the migration stops, which is the right moment
  # for a person to look.
  def up do
    execute """
    DELETE FROM flyer_placements p
     USING (
       SELECT id,
              row_number() OVER (
                PARTITION BY project_id, lower(trim(venue_name)), lower(trim(coalesce(address, '')))
                ORDER BY scans_count DESC, inserted_at, id
              ) AS n
         FROM flyer_placements
     ) ranked
     WHERE p.id = ranked.id
       AND ranked.n > 1
       AND p.scans_count = 0
       AND NOT EXISTS (SELECT 1 FROM flyer_scans s WHERE s.placement_id = p.id)
    """

    execute """
    CREATE UNIQUE INDEX flyer_placements_one_per_place_index
        ON flyer_placements (project_id, lower(trim(venue_name)), lower(trim(coalesce(address, ''))))
    """
  end

  def down do
    execute "DROP INDEX flyer_placements_one_per_place_index"
  end
end
