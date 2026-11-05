defmodule ColdForge.DoNotContact do
  @moduledoc """
  A project's do-not-contact list: companies that must not be emailed, called
  or mailed, however they turn up.

  A company matches by name or by web domain. Names are compared loosely —
  case, punctuation, "&" against "and", a trailing "LLC" — and an entry matches
  any prospect whose name *starts* with it, so "High Point Roofing" covers
  "High Point Roofing & Construction, LLC". It doesn't match a name merely
  containing it: "Premier Roofing & Exteriors" leaves "Premier Roofing" alone.

  Adding a company also deals with the prospects already there: their email
  campaigns stop, their address goes on the global suppression list, and a
  "Not interested" call is logged so they leave the call queue. They stay on
  file, so the history of what was sent is kept. New prospects that match are
  refused — by a search's Add, a CSV import, or by hand.
  """
  import Ecto.Query, warn: false

  alias ColdForge.{Calling, Outreach, Repo}
  alias ColdForge.DoNotContact.Entry
  alias ColdForge.Outreach.{Enrollment, Prospect}

  def list(project_id) do
    Entry
    |> where([e], e.project_id == ^project_id)
    |> order_by([e], asc: e.name)
    |> Repo.all()
  end

  def change(%Entry{} = entry, attrs \\ %{}), do: Entry.changeset(entry, attrs)

  @doc """
  Adds a company and applies it to the project's prospects. Returns the entry
  and how many prospects it caught.
  """
  def add(project_id, attrs) do
    Repo.transaction(fn ->
      case %Entry{project_id: project_id} |> Entry.changeset(attrs) |> Repo.insert() do
        {:ok, entry} ->
          caught =
            project_id
            |> matching_prospects([entry])
            |> Enum.map(&stop(&1, entry))

          {entry, length(caught)}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Takes a company off the list. Prospects it caught stay stopped: being taken
  off the list doesn't mean they asked to hear from us.
  """
  def remove(%Entry{} = entry), do: Repo.delete(entry)

  @doc """
  The entry a company would match, or nil. Takes anything with any of
  `:company`, `:website` and `:email` — prospect attrs, a prospect, or an org.
  """
  def match(project_id, company) when is_binary(project_id) do
    match_entries(list(project_id), company)
  end

  def match(_project_id, _company), do: nil

  @doc "The prospects of a project caught by its list."
  def caught(project_id), do: matching_prospects(project_id, list(project_id))

  defp matching_prospects(_project_id, []), do: []

  defp matching_prospects(project_id, entries) do
    Prospect
    |> where([p], p.project_id == ^project_id)
    |> Repo.all()
    |> Enum.filter(&match_entries(entries, &1))
  end

  @doc "The entry among `entries` a company matches, or nil — for checking many at once."
  def match_entries(entries, company) do
    name = company |> field(:company) |> normalize()
    domains = [field(company, :website), field(company, :email)] |> Enum.map(&domain/1)

    Enum.find(entries, fn entry ->
      entry_name = normalize(entry.name)

      (entry_name != "" and name != "" and String.starts_with?(name, entry_name)) or
        (entry.domain not in [nil, ""] and entry.domain in domains)
    end)
  end

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # Email, campaigns and calls, in that order of urgency.
  defp stop(%Prospect{} = prospect, %Entry{} = entry) do
    if prospect.email not in [nil, ""] do
      Outreach.suppress(prospect.email, "manual", %{
        notes: "Do not contact: #{entry.name}",
        project_id: prospect.project_id
      })
    end

    Enrollment
    |> where([e], e.prospect_id == ^prospect.id and e.status == "active")
    |> Repo.update_all(
      set: [status: "stopped", stopped_reason: "do_not_contact", next_send_at: nil]
    )

    # Once is enough: a prospect whose calling already ended — a second listing,
    # or a "Do not call" logged by hand — isn't given another call record.
    unless calls_closed?(prospect) do
      {:ok, _call} =
        Calling.log_call(prospect, %{
          "outcome" => "not_interested",
          "notes" => "On the do-not-contact list (#{entry.name})."
        })
    end

    prospect
  end

  defp calls_closed?(%Prospect{id: id}) do
    Repo.exists?(
      from c in ColdForge.Calling.Call,
        where:
          c.prospect_id == ^id and c.outcome in ["not_interested", "do_not_call", "wrong_number"]
    )
  end

  @doc """
  A company name for comparing: lower case, "&" as "and", no punctuation, no
  trailing company type.
  """
  def normalize(nil), do: ""

  def normalize(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/[’'`]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
    |> String.replace(~r/\s+(llc|inc|co|corp|company|ltd)$/, "")
    |> String.replace(" ", "")
  end

  @doc """
  The bare domain of a website or an email address: `https://www.Foo.com/x`
  and `sales@foo.com` are both `foo.com`.
  """
  def domain(nil), do: nil

  def domain(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    host =
      cond do
        value == "" ->
          nil

        String.contains?(value, "@") and not String.contains?(value, "/") ->
          value |> String.split("@") |> List.last()

        String.contains?(value, "://") ->
          URI.parse(value).host

        true ->
          value |> String.split(["/", "?", "#"]) |> hd()
      end

    case host do
      nil -> nil
      "" -> nil
      host -> String.replace_prefix(host, "www.", "")
    end
  end
end
