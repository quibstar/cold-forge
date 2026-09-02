defmodule ColdForge.Repo.Migrations.RenameSequencesToCampaigns do
  use Ecto.Migration

  # The UI has called these campaigns since the blast/sequence split was
  # collapsed. Leaving the tables named `sequences` meant every reader had to
  # hold a translation in their head.
  #
  # Indexes and constraints are renamed alongside the tables, not just for
  # tidiness: Ecto derives the name it expects from table + fields, so a
  # `unique_constraint([:campaign_id, :prospect_id])` looking for
  # `enrollments_campaign_id_prospect_id_index` would miss an index still called
  # `enrollments_sequence_id_..._index`. The failure mode is a raw Postgres
  # error escaping to the user instead of a form error.

  def up do
    rename table(:sequences), to: table(:campaigns)
    rename table(:sequence_steps), to: table(:campaign_steps)

    rename table(:campaign_steps), :sequence_id, to: :campaign_id
    rename table(:enrollments), :sequence_id, to: :campaign_id
    rename table(:messages), :sequence_step_id, to: :campaign_step_id

    rename_objects(:up)
  end

  def down do
    rename_objects(:down)

    rename table(:messages), :campaign_step_id, to: :sequence_step_id
    rename table(:enrollments), :campaign_id, to: :sequence_id
    rename table(:campaign_steps), :campaign_id, to: :sequence_id

    rename table(:campaign_steps), to: table(:sequence_steps)
    rename table(:campaigns), to: table(:sequences)
  end

  # Indexes and constraints rename through different statements: ALTER INDEX
  # covers plain and unique indexes (and primary keys, which rename their
  # constraint with the index), but a foreign key is only a constraint and
  # needs ALTER TABLE ... RENAME CONSTRAINT. Using ALTER INDEX on an FK is not
  # an error — it just reports "does not exist, skipping" and leaves the old
  # name in place.
  @index_renames [
    {"sequences_pkey", "campaigns_pkey"},
    {"sequences_project_id_index", "campaigns_project_id_index"},
    {"sequence_steps_pkey", "campaign_steps_pkey"},
    {"sequence_steps_sequence_id_position_index", "campaign_steps_campaign_id_position_index"},
    {"enrollments_sequence_id_prospect_id_index", "enrollments_campaign_id_prospect_id_index"}
  ]

  @constraint_renames [
    # {table, old, new}
    {"campaigns", "sequences_project_id_fkey", "campaigns_project_id_fkey"},
    {"campaign_steps", "sequence_steps_sequence_id_fkey", "campaign_steps_campaign_id_fkey"},
    {"enrollments", "enrollments_sequence_id_fkey", "enrollments_campaign_id_fkey"},
    {"messages", "messages_sequence_step_id_fkey", "messages_campaign_step_id_fkey"}
  ]

  defp rename_objects(direction) do
    for {old, new} <- @index_renames do
      {from, to} = if direction == :up, do: {old, new}, else: {new, old}
      execute("ALTER INDEX IF EXISTS #{from} RENAME TO #{to}")
    end

    for {table, old, new} <- @constraint_renames do
      {from, to} = if direction == :up, do: {old, new}, else: {new, old}
      execute("ALTER TABLE #{table} RENAME CONSTRAINT #{from} TO #{to}")
    end

    # Postgres 18 gives NOT NULL constraints real names, which carry the old
    # table name after a rename. They're cosmetic — nothing in the app refers to
    # them — but a constraint called `sequences_name_not_null` on a table called
    # `campaigns` is exactly the confusion this migration exists to remove.
    execute(not_null_rename_sql(direction))
  end

  defp not_null_rename_sql(direction) do
    {old_prefixes, new_prefix_expr} =
      if direction == :up do
        {["sequences_", "sequence_steps_"],
         "replace(replace(con.conname, 'sequence_steps_', 'campaign_steps_'), 'sequences_', 'campaigns_')"}
      else
        {["campaigns_", "campaign_steps_"],
         "replace(replace(con.conname, 'campaign_steps_', 'sequence_steps_'), 'campaigns_', 'sequences_')"}
      end

    likes = Enum.map_join(old_prefixes, " OR ", &"con.conname LIKE '#{&1}%'")

    """
    DO $$
    DECLARE r RECORD;
    BEGIN
      FOR r IN
        SELECT con.conname AS old_name, #{new_prefix_expr} AS new_name, rel.relname AS table_name
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE con.contype = 'n' AND (#{likes})
      LOOP
        EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I', r.table_name, r.old_name, r.new_name);
      END LOOP;
    END $$;
    """
  end
end
