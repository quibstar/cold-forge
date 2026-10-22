defmodule Mix.Tasks.ColdForge.Prospects.ImportExteriorpro do
  @shortdoc "Move ExteriorPro's cold-call list into a Cold Forge project"

  @moduledoc """
  Copies ExteriorPro's `prospects` table into Cold Forge, into a project of its
  own.

  Two separate Postgres databases, so this reads one over a second connection
  and inserts into the other — there is no migration that can reach across.
  `ColdForge.Outreach.ExteriorproImport` holds the mapping and explains it.

      mix cold_forge.prospects.import_exteriorpro                   # the plan
      mix cold_forge.prospects.import_exteriorpro --write           # apply it

  **A dry run is the default and it writes nothing.** This moves somebody's
  working sales list between two live databases, and the mapping has judgment
  in it — a status that means one thing in one app and another in the other, a
  quarter of a list with a placeholder where the phone number goes. Those are
  easier to argue with in a plan than to undo.

  ## Options

    * `--from URL` — the ExteriorPro database. Defaults to
      `$EXTERIORPRO_DATABASE_URL`, then to the local development database.
    * `--project SLUG` — the Cold Forge project to file them under. Defaults to
      `exteriorpro-cold-list`. Created on `--write` if it isn't there, copying
      the sender identity from an existing project, since a from-address
      invented by an import script is one nobody notices is wrong until it has
      sent mail.
    * `--write` — actually do it.

  Safe to run twice. Rows are matched on the ExteriorPro id kept in
  `custom_fields`, and a second run fills in what is missing rather than
  resetting the Cold Forge row, which by then is the working copy.
  """

  use Mix.Task

  import Ecto.Query

  alias ColdForge.Outreach
  alias ColdForge.Outreach.{ExteriorproImport, Project, Prospect}
  alias ColdForge.Repo

  @default_source "postgresql://postgres:postgres@localhost/exteriorpro_dev"
  @default_slug "exteriorpro-cold-list"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv,
        strict: [from: :string, project: :string, write: :boolean]
      )

    Mix.Task.run("app.start")

    write? = Keyword.get(opts, :write, false)
    slug = Keyword.get(opts, :project, @default_slug)

    url =
      Keyword.get(opts, :from) || System.get_env("EXTERIORPRO_DATABASE_URL") || @default_source

    rows = read_source(url)
    project = find_project(slug)
    results = Enum.map(rows, &{&1, classify(&1, project)})

    report(results, url, slug, project)

    if write? do
      project = project || create_project!(slug)
      apply_results(results, project)
    else
      Mix.shell().info([
        :yellow,
        "\nNothing written. Re-run with --write to apply it.",
        :reset
      ])
    end
  end

  ## Reading ExteriorPro

  defp read_source(url) do
    config = url |> Ecto.Repo.Supervisor.parse_url() |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(config)

    # `id::text` because the uuid would otherwise come back as sixteen raw
    # bytes, and it is going into a map as a string.
    columns =
      ExteriorproImport.columns()
      |> Enum.map_join(", ", fn
        "id" -> "id::text"
        column -> column
      end)

    query = "select #{columns} from prospects order by company"

    case Postgrex.query(conn, query, []) do
      {:ok, result} ->
        GenServer.stop(conn)
        Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))

      {:error, error} ->
        GenServer.stop(conn)
        Mix.raise("Could not read ExteriorPro's prospects: #{Exception.message(error)}")
    end
  rescue
    error in [DBConnection.ConnectionError] ->
      Mix.raise("Could not connect to #{redact(url)}: #{Exception.message(error)}")
  end

  ## Classifying

  defp classify(row, project) do
    project_id = project && project.id

    ExteriorproImport.classify(row, project_id, existing(project, row["id"]))
  end

  # Matched on the ExteriorPro id kept in `custom_fields`, which is exact. A
  # phone number isn't: a quarter of this list has a placeholder in that column
  # rather than a number, and they would all match each other.
  defp existing(nil, _id), do: nil

  defp existing(project, id) do
    Prospect
    |> where([p], p.project_id == ^project.id)
    |> where([p], fragment("?->>'exteriorpro_id' = ?", p.custom_fields, ^id))
    |> Repo.one()
  end

  ## Reporting

  defp report(results, url, slug, project) do
    counts = Enum.frequencies_by(results, fn {_row, result} -> bucket(result) end)

    Mix.shell().info([
      :bright,
      "\nExteriorPro prospects -> Cold Forge\n",
      :reset,
      "\n  from     #{redact(url)}",
      "\n  into     #{project_line(slug, project)}",
      "\n"
    ])

    Mix.shell().info("\nWhat this would do to #{length(results)} rows:\n")

    for {bucket, note} <- [
          {:new, "created here"},
          {:changed, "already here, with blanks this would fill"},
          {:unchanged, "already here, nothing to add"},
          {:invalid, "not importable"}
        ] do
      Mix.shell().info("  #{pad(Map.get(counts, bucket, 0))}  #{pad_name(bucket)}  #{note}")
    end

    describe_new(results)
    describe_changed(results)
    describe_invalid(results)
  end

  # The things worth knowing before this lands, rather than after. Each one has
  # bitten somebody: a phone column with prose in it, a call list with no email
  # addresses on it at all, a script that didn't come across.
  defp describe_new(results) do
    new = for {row, {:new, attrs}} <- results, do: {row, attrs}

    if new != [] do
      {dialable, placeholders} =
        Enum.split_with(new, fn {_row, attrs} ->
          Prospect.dialable?(%Prospect{phone: attrs.phone})
        end)

      emailed = Enum.count(new, fn {_row, attrs} -> attrs.email end)

      Mix.shell().info("\nOf the #{length(new)} to create:\n")
      Mix.shell().info("  #{pad(length(dialable))}  have a number that can be dialled")

      Mix.shell().info(
        "  #{pad(length(placeholders))}  have something else in the phone column#{sample(placeholders)}"
      )

      Mix.shell().info(
        "  #{pad(emailed)}  have an email address — the rest can be called but never emailed"
      )
    end
  end

  defp describe_changed(results) do
    changed = for {row, {:changed, _changes, fields}} <- results, do: {row, fields}

    if changed != [] do
      Mix.shell().info("\nAlready here, fields this would fill:\n")

      for {row, fields} <- Enum.take(changed, 20),
          do: Mix.shell().info("  #{row["company"]} — #{Enum.join(fields, ", ")}")

      if length(changed) > 20,
        do: Mix.shell().info("  … and #{length(changed) - 20} more")
    end
  end

  defp describe_invalid(results) do
    invalid = for {row, {:invalid, reason}} <- results, do: {row, reason}

    if invalid != [] do
      Mix.shell().info([:red, "\nSkipped:\n", :reset])

      for {row, reason} <- invalid,
          do: Mix.shell().info("  #{row["company"] || "(no company)"} — #{reason}")
    end
  end

  ## Writing

  defp apply_results(results, project) do
    project_id = project.id

    {created, updated, failed} =
      Repo.transaction(
        fn ->
          Enum.reduce(results, {0, 0, []}, fn {row, result}, acc ->
            write(row, result, project_id, acc)
          end)
        end,
        timeout: :infinity
      )
      |> case do
        {:ok, totals} -> totals
      end

    Mix.shell().info([
      :green,
      "\nDone. #{created} created, #{updated} updated.",
      :reset
    ])

    if failed != [] do
      Mix.shell().info([:red, "\n#{length(failed)} failed:\n", :reset])

      for {company, message} <- Enum.reverse(failed),
          do: Mix.shell().info("  #{company} — #{message}")
    end
  end

  # The project wasn't there when the plan was drawn, so the ids in it weren't
  # either; the attrs are rebuilt against the project that now exists.
  defp write(row, {:new, _attrs}, project_id, {created, updated, failed}) do
    case row |> ExteriorproImport.to_attrs(project_id) |> Outreach.create_prospect() do
      {:ok, _prospect} -> {created + 1, updated, failed}
      {:error, changeset} -> {created, updated, [{row["company"], errors(changeset)} | failed]}
    end
  end

  defp write(row, {:changed, changes, _fields}, project_id, {created, updated, failed}) do
    case existing(%Project{id: project_id}, row["id"]) do
      nil ->
        write(row, {:new, nil}, project_id, {created, updated, failed})

      prospect ->
        case Outreach.update_prospect(prospect, changes) do
          {:ok, _prospect} ->
            {created, updated + 1, failed}

          {:error, changeset} ->
            {created, updated, [{row["company"], errors(changeset)} | failed]}
        end
    end
  end

  defp write(_row, _result, _project_id, acc), do: acc

  defp create_project!(slug) do
    donor =
      Outreach.list_projects()
      |> Enum.find(& &1.from_email)
      |> Kernel.||(
        Mix.raise("""
        No project to copy a sender identity from, and this won't invent one.
        Create a project first (Admin -> Projects -> New), then re-run with
        --project <its slug>.
        """)
      )

    attrs = %{
      "name" => "ExteriorPro cold list",
      "slug" => slug,
      "from_name" => donor.from_name,
      "from_email" => donor.from_email,
      "reply_to" => donor.reply_to,
      "phone" => donor.phone,
      "postal_address" => donor.postal_address,
      "timezone" => donor.timezone
    }

    case Outreach.create_project(attrs) do
      {:ok, project} ->
        Mix.shell().info("Created project #{project.name} (#{project.slug}).")
        project

      {:error, changeset} ->
        Mix.raise("Could not create the project: #{errors(changeset)}")
    end
  end

  ## Shared

  defp find_project(slug), do: Outreach.get_project_by_slug(slug)

  defp project_line(slug, nil), do: "#{slug} — not there yet, --write would create it"
  defp project_line(_slug, project), do: "#{project.name} (#{project.slug})"

  defp bucket({:new, _attrs}), do: :new
  defp bucket({:changed, _changes, _fields}), do: :changed
  defp bucket({:invalid, _reason}), do: :invalid
  defp bucket(:unchanged), do: :unchanged

  defp sample([]), do: ""

  defp sample([{_row, attrs} | _] = placeholders) do
    " (#{length(placeholders)} like #{inspect(attrs.phone)})"
  end

  defp pad(count), do: count |> to_string() |> String.pad_leading(4)
  defp pad_name(bucket), do: bucket |> to_string() |> String.pad_trailing(9)

  # A URL with a password in it should not end up in a terminal scrollback.
  defp redact(url) do
    case URI.parse(url) do
      %URI{userinfo: nil} -> url
      %URI{} = uri -> URI.to_string(%{uri | userinfo: redact_userinfo(uri.userinfo)})
    end
  end

  defp redact_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, _password] -> user <> ":***"
      [user] -> user
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
