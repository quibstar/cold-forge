# Moves the scripts out of the two map columns on `projects` and into
# `call_scripts` rows, once, before `ProjectScriptMapsRemoved` drops them.
#
#     mix run priv/repo/seeds/call_scripts.exs            # the plan
#     mix run priv/repo/seeds/call_scripts.exs --write
#
# Read with raw SQL on purpose: `Project` has already dropped the fields, and a
# schema that still carried them only so a one-off could read them would be a
# schema lying about the table for as long as nobody noticed.
#
# Script 1 arrives as three keys — opener, problem_question, objections —
# because ExteriorPro's generator wrote a spreadsheet column per section. It is
# one script and goes back together as one row.

import Ecto.Query

alias ColdForge.Calling.Scripts
alias ColdForge.Outreach
alias ColdForge.Outreach.CallScript
alias ColdForge.Repo

write? = "--write" in System.argv()

maps =
  case Repo.query("select id, name, call_scripts, voicemail_scripts from projects", []) do
    {:ok, %{rows: rows}} -> rows
    {:error, %Postgrex.Error{}} -> []
  end

if maps == [] do
  IO.puts("\nNo map columns left to read — already moved.\n")
else
  plan =
    Enum.map(maps, fn [id, name, scripts, voicemails] ->
      scripts = scripts || %{}
      voicemails = voicemails || %{}

      script_rows =
        [
          {"Script 1", 1,
           [scripts["opener"], scripts["problem_question"], scripts["objections"]]
           |> Enum.reject(&(&1 in [nil, ""]))
           |> Enum.join("\n\n")},
          {"Script 2", 2, scripts["script_direct"]},
          {"NEPQ Awareness", 3, scripts["script_nepq"]}
        ]
        |> Enum.reject(fn {_n, _p, body} -> body in [nil, ""] end)
        |> Enum.map(fn {n, p, body} -> %{kind: "script", name: n, position: p, body: body} end)

      # The per-business voicemail is the first attempt; the rest of the cadence
      # comes from the built-in wording, which is where it lived before.
      voicemail_rows =
        Scripts.defaults()
        |> Enum.map(fn default ->
          body =
            voicemails[to_string(default.position)] ||
              if(default.position == 1, do: scripts["voicemail"]) ||
              default.body

          %{kind: "voicemail", name: default.name, position: default.position, body: body}
        end)

      {id, name, script_rows ++ voicemail_rows}
    end)

  for {_id, name, rows} <- plan do
    IO.puts("\n#{name}")

    for row <- rows do
      IO.puts(
        "  #{row.kind |> String.pad_trailing(9)} #{row.position}  " <>
          "#{String.pad_trailing(row.name, 52)} #{byte_size(row.body)} bytes"
      )
    end
  end

  if write? do
    inserted =
      for {project_id, _name, rows} <- plan, row <- rows, reduce: 0 do
        count ->
          existing =
            Repo.one(
              from s in CallScript,
                where:
                  s.project_id == ^project_id and s.kind == ^row.kind and
                    s.position == ^row.position
            )

          case existing do
            nil ->
              {:ok, _} =
                row |> Map.put(:project_id, project_id) |> Outreach.create_call_script()

              count + 1

            _already ->
              count
          end
      end

    IO.puts("\nWrote #{inserted} rows. Re-running adds nothing.\n")
  else
    IO.puts("\nNothing written. Re-run with --write to apply it.\n")
  end
end
