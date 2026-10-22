defmodule ColdForge.Outreach.ExteriorproImport do
  @moduledoc """
  The one-time move of ExteriorPro's own cold-call list into Cold Forge.

  ExteriorPro grew a `prospecting` context — the list of contractors we are
  selling *to* — because that was where the person doing the selling was
  already logged in. Its own moduledoc admitted the problem: nothing in the
  product read the table, it belonged to no organization, and it sat in the
  same database as paying contractors' jobs and invoices. This is where it
  belongs, beside the campaigns and the call queue.

  Two separate Postgres databases, so this is a read out of one and an insert
  into the other rather than an Ecto migration. `Mix.Tasks.ColdForge.Prospects.ImportExteriorpro`
  is the plumbing; this module is the part worth testing — what each column
  becomes, and what a second run does.

  ## The mapping

  Most of it is a rename. The interesting half is the six columns of
  hand-written script, which become `custom_fields` keys: see
  `ColdForge.Outreach.CallScripts` for why there, and what had to change about
  the editor before it was safe.

      company               -> company
      contact_name          -> first_name + last_name   (split on the first space)
      contact_role          -> title
      phone                 -> phone                    (verbatim, placeholders and all)
      email                 -> email
      website               -> website
      trades                -> industry + custom_fields.trades
      status                -> status                   (see below)
      notes                 -> notes
      next_action_on        -> next_call_at
      last_contacted_at     -> last_called_at
      city, state_province  -> custom_fields.city, custom_fields.state
      fit                   -> custom_fields.fit        (the call queue orders on it)
      employee_estimate     -> custom_fields.employee_estimate
      current_software      -> custom_fields.current_software
      opener, problem_question, objections, voicemail,
      script_direct, script_nepq
                            -> custom_fields, same names
      source                -> custom_fields.source_list
      id                    -> custom_fields.exteriorpro_id
      phone_digits          -> dropped

  `phone_digits` is the only column deliberately thrown away: it was a
  deduplication key, and the call queue derives what it needs from `phone`.

  `source` is set to `"exteriorpro:prospecting"` on every row so the origin is
  one `where` clause away forever. The list name that was in that column —
  "NEPQ call sheet" — moves to `custom_fields.source_list`, because it says
  which sheet a row came off, which is a different question.

  ## Status is not the same word in both apps

  ExteriorPro's statuses describe a sales conversation: `new`, `callback`,
  `contacted`, `won`, `lost`. Cold Forge's describe whether outreach should
  stop: `new`, `active`, `replied`, `bounced`, `unsubscribed`, `completed`.
  They are not translations of each other, so the mapping preserves what the
  *call queue* did rather than the word:

    * `new`, `callback`, `contacted` -> `new`. All three were in ExteriorPro's
      "due" list, and all three should be in Cold Forge's call queue. A
      callback's date rides along in `next_call_at`, which is what orders it.
    * `won` -> `replied`. Signed up, out of the cold queue — the same state a
      conversation leaves a prospect in here.
    * `lost` -> `unsubscribed`, plus `do_not_call`. ExteriorPro excluded `lost`
      from its queue; these two are how Cold Forge says that durably, and
      erring towards not ringing somebody who already said no is the right
      direction to err in.

  Anything other than `new` is also written verbatim to
  `custom_fields.exteriorpro_status`, so a mapping somebody disagrees with
  later can be argued with from the data rather than from memory.

  ## Re-running it

  Rows are matched on `custom_fields.exteriorpro_id`, which is exact — unlike
  a phone number, which a quarter of this list hasn't got. A second run fills
  in what the Cold Forge row is *missing* and nothing else, because by then
  the Cold Forge row is the working copy: a note typed after a call, a status
  moved on, a callback booked.

  The six script columns that used to ride along here are a project's now,
  written once rather than copied onto every row — see
  `ColdForge.Outreach.CallScript`. This brings the prospects; the words are
  edited on their own screen.
  """

  alias ColdForge.Outreach.Prospect

  # The columns read out of ExteriorPro, which is also the select list.
  @columns ~w(id company contact_name contact_role phone email website city
              state_province trades employee_estimate current_software source
              fit status next_action_on notes last_contacted_at opener
              problem_question objections voicemail script_direct script_nepq)

  @doc "The ExteriorPro columns this import reads."
  def columns, do: @columns

  @doc "The `source` written on every row, so the origin stays traceable."
  def source, do: "exteriorpro:prospecting"

  # A callback is a date, and the queue compares a timestamp. 13:00 UTC is
  # nine in the morning in the project's timezone, which is when somebody would
  # actually ring: midnight UTC would make the row due at eight the evening
  # before.
  @calling_hour_utc ~T[13:00:00]

  @doc """
  One ExteriorPro row as Cold Forge prospect attributes.

  Takes the row as a map with string keys, and the project to file it under.
  Atom keys throughout, because these go straight to the changeset and never
  through a form.
  """
  def to_attrs(row, project_id) when is_map(row) do
    {first, last} = split_name(row["contact_name"])

    %{
      project_id: project_id,
      company: presence(row["company"]),
      first_name: first,
      last_name: last,
      title: presence(row["contact_role"]),
      phone: presence(row["phone"]),
      email: presence(row["email"]),
      website: presence(row["website"]),
      industry: primary_trade(row["trades"]),
      notes: presence(row["notes"]),
      source: source(),
      status: status(row["status"]),
      do_not_call: row["status"] == "lost",
      next_call_at: next_call_at(row["next_action_on"]),
      last_called_at: timestamp(row["last_contacted_at"]),
      # Evidence of one attempt, which is all the row says. ExteriorPro's call
      # log is empty, so there is no history to count.
      call_attempts: if(row["last_contacted_at"], do: 1, else: 0),
      custom_fields: custom_fields(row)
    }
  end

  @doc """
  Everything that has no column of its own here, keyed as a merge tag would
  reach it.
  """
  def custom_fields(row) when is_map(row) do
    %{
      "exteriorpro_id" => presence(row["id"]),
      "city" => presence(row["city"]),
      "state" => presence(row["state_province"]),
      "trades" => trades(row["trades"]),
      "fit" => presence(row["fit"]),
      "employee_estimate" => presence(row["employee_estimate"]),
      "current_software" => presence(row["current_software"]),
      "source_list" => presence(row["source"]),
      "exteriorpro_status" => original_status(row["status"])
    }
    |> drop_blanks()
  end

  @doc """
  What importing this row would do, given the Cold Forge prospect already
  matched to it (or `nil`).

  Returns `{:new, attrs}`, `{:changed, attrs, fields}`, `:unchanged`, or
  `{:invalid, reason}` — the same shape of answer `Outreach.Importer.analyze/3`
  gives, for the same reason: a list that turns out to be half-garbage should
  be found out before it is in the database, not after.
  """
  def classify(row, project_id, existing) do
    attrs = to_attrs(row, project_id)

    cond do
      blank?(attrs.company) ->
        {:invalid, "no company name"}

      blank?(attrs.phone) and blank?(attrs.email) ->
        {:invalid, "neither a phone number nor an email address"}

      is_nil(existing) ->
        {:new, attrs}

      true ->
        case changes(existing, attrs) do
          changes when map_size(changes) == 0 -> :unchanged
          changes -> {:changed, changes, change_labels(changes)}
        end
    end
  end

  @doc """
  What a second run would write onto a prospect that is already here.

  Blanks only. A value already on the Cold Forge row is the working copy — a
  note somebody typed after a call, a number somebody corrected — and a
  re-import that overwrote it would be destroying the newer of the two.
  """
  def changes(%Prospect{} = existing, attrs) do
    scalars =
      for {field, value} <- Map.take(attrs, scalar_fields()),
          not blank?(value),
          blank?(Map.get(existing, field)),
          into: %{},
          do: {field, value}

    case custom_field_changes(existing, attrs) do
      fields when map_size(fields) == 0 -> scalars
      fields -> Map.put(scalars, :custom_fields, Map.merge(existing.custom_fields || %{}, fields))
    end
  end

  # Only what a person would have typed. Deliberately not `status`,
  # `next_call_at`, `last_called_at`, `call_attempts`, `do_not_call` or
  # `source`: those are Cold Forge's own working state once the row is here, and
  # a re-import has no business resetting them.
  defp scalar_fields,
    do: [:company, :first_name, :last_name, :title, :phone, :email, :website, :industry, :notes]

  defp custom_field_changes(%Prospect{} = existing, attrs) do
    current = existing.custom_fields || %{}

    for {key, value} <- attrs.custom_fields,
        not blank?(value),
        blank?(Map.get(current, key)),
        into: %{},
        do: {key, value}
  end

  defp change_labels(changes) do
    changes
    |> Enum.flat_map(fn
      {:custom_fields, fields} -> Map.keys(fields)
      {field, _value} -> [to_string(field)]
    end)
    |> Enum.sort()
  end

  @doc """
  A contact name split into the two columns Cold Forge keeps.

  One field became two, and a name is not reliably two words — so the first
  word is the first name and everything after it is the last, which keeps
  "Mary Beth Van Dyke" whole rather than deciding where a surname starts.
  """
  def split_name(name) do
    case name |> presence() |> to_string() |> String.split(" ", parts: 2) do
      [""] -> {nil, nil}
      [first] -> {first, nil}
      [first, rest] -> {first, presence(rest)}
    end
  end

  @doc "ExteriorPro's status as Cold Forge's. See the moduledoc."
  def status("won"), do: "replied"
  def status("lost"), do: "unsubscribed"
  def status(_other), do: "new"

  # Worth recording only where the two words differ. Every row on this list is
  # `new`, and 112 rows each carrying a note that says "new" would be clutter
  # in the field editor rather than provenance.
  defp original_status(status) when status in [nil, "", "new"], do: nil
  defp original_status(status), do: status

  defp next_call_at(%Date{} = date),
    do: date |> DateTime.new!(@calling_hour_utc, "Etc/UTC") |> DateTime.truncate(:second)

  defp next_call_at(_), do: nil

  defp timestamp(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp timestamp(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp timestamp(_), do: nil

  # `industry` is one word in Cold Forge and `trades` is a list in ExteriorPro.
  # The first trade is the one that answers "what kind of shop is this", which
  # is what the merge tag is for; the full list stays in `custom_fields`.
  defp primary_trade([trade | _]), do: presence(trade)
  defp primary_trade(_), do: nil

  defp trades(trades) when is_list(trades) do
    case trades |> Enum.map(&presence/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp trades(_), do: nil

  defp drop_blanks(fields), do: Map.reject(fields, fn {_key, value} -> blank?(value) end)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
