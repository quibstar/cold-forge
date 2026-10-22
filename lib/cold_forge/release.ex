defmodule ColdForge.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :cold_forge

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Gives every project that has no voicemails the four built-in ones.

  A release has no Mix, so `priv/repo/seeds/call_scripts.exs` cannot run on the
  box — and it reads map columns a migration has since dropped, so it would
  find nothing there anyway. This is the part of it worth keeping: a project
  with no voicemails has no cadence at all, and the call screen shows an empty
  panel until something writes them.

  Idempotent. A project that already has one is left alone, so this never
  overwrites wording somebody changed.
  """
  def seed_call_scripts do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(ColdForge.Repo, &seed_voicemails/1)
  end

  defp seed_voicemails(repo) do
    import Ecto.Query

    projects = repo.all(ColdForge.Outreach.Project)

    with_voicemails =
      repo.all(
        from s in ColdForge.Outreach.CallScript,
          where: s.kind == "voicemail",
          select: s.project_id,
          distinct: true
      )

    seeded =
      for project <- projects,
          project.id not in with_voicemails,
          default <- ColdForge.Calling.Scripts.defaults() do
        {:ok, _} =
          %ColdForge.Outreach.CallScript{}
          |> ColdForge.Outreach.CallScript.changeset(
            Map.merge(default, %{project_id: project.id, kind: "voicemail"})
          )
          |> repo.insert()

        project.name
      end

    case Enum.uniq(seeded) do
      [] -> IO.puts("Every project already has voicemails. Nothing written.")
      names -> IO.puts("Seeded four voicemails for: #{Enum.join(names, ", ")}")
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
