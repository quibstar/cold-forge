defmodule ColdForge.Repo.Migrations.MergeVoicemailsIntoAScript do
  use Ecto.Migration

  import Ecto.Query

  # Voicemails were their own list: shown under every script tab on the call
  # page, with a "due next" badge for a cadence nothing on the page ever
  # recorded. They are words to read, the same as a script, so each project's
  # become one script called "Voicemails" — a tab like any other, numbered
  # sections in their old order.
  #
  # In Elixir rather than SQL for the key: ids are UUIDv7, made by the app.
  def up do
    voicemails =
      repo().all(
        from(s in "call_scripts",
          where: s.kind == "voicemail",
          order_by: [asc: s.project_id, asc: s.position],
          select: %{project_id: s.project_id, position: s.position, name: s.name, body: s.body}
        )
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {project_id, rows} <- Enum.group_by(voicemails, & &1.project_id) do
      last =
        repo().one(
          from(s in "call_scripts",
            where: s.project_id == ^project_id and s.kind == "script",
            select: max(s.position)
          )
        ) || 0

      body =
        rows
        |> Enum.sort_by(& &1.position)
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {row, n} ->
          "VOICEMAIL #{n} — #{String.upcase(row.name)}\n#{row.body}"
        end)

      {:ok, id} = Ecto.UUID.dump(ColdForge.UUIDv7.generate())

      repo().insert_all("call_scripts", [
        %{
          id: id,
          project_id: project_id,
          kind: "script",
          name: "Voicemails",
          body: body,
          position: last + 1,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    repo().delete_all(from(s in "call_scripts", where: s.kind == "voicemail"))
  end

  # The merged script keeps every word; splitting it back is a job for the
  # Scripts page, not a guess here.
  def down, do: :ok
end
