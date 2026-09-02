defmodule ColdForge.Outreach do
  @moduledoc """
  Projects, prospects, sequences and enrollments — everything the operator
  edits directly. Actually putting mail on the wire is `ColdForge.Sending`.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Repo
  alias ColdForge.Sending.Window

  alias ColdForge.Outreach.{
    Enrollment,
    Message,
    Project,
    Prospect,
    Sequence,
    SequenceStep,
    Suppression
  }

  ## Projects

  def list_projects do
    Repo.all(from p in Project, order_by: [desc: p.active, asc: p.name])
  end

  def list_active_projects do
    Repo.all(from p in Project, where: p.active, order_by: p.name)
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def get_project_by_slug(slug), do: Repo.get_by(Project, slug: slug)

  def create_project(attrs) do
    %Project{} |> Project.changeset(attrs) |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project |> Project.changeset(attrs) |> Repo.update()
  end

  def delete_project(%Project{} = project), do: Repo.delete(project)

  def change_project(%Project{} = project, attrs \\ %{}),
    do: Project.changeset(project, attrs)

  ## Prospects

  @doc """
  Prospects for a project, newest first, with optional `:search` and `:status`
  filters from the index page.
  """
  def list_prospects(project_id, opts \\ []) do
    Prospect
    |> where([p], p.project_id == ^project_id)
    |> filter_by_status(opts[:status])
    |> filter_by_search(opts[:search])
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  defp filter_by_status(query, status) when status in [nil, "", "all"], do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_search(query, search) when search in [nil, ""], do: query

  defp filter_by_search(query, search) do
    like = "%#{String.trim(search)}%"

    where(
      query,
      [p],
      ilike(type(p.email, :string), ^like) or ilike(p.first_name, ^like) or
        ilike(p.last_name, ^like) or ilike(p.company, ^like)
    )
  end

  def get_prospect!(id), do: Repo.get!(Prospect, id)

  def get_prospect_by_unsubscribe_token(token) when is_binary(token),
    do: Repo.get_by(Prospect, unsubscribe_token: token)

  def get_prospect_by_unsubscribe_token(_), do: nil

  def create_prospect(attrs) do
    %Prospect{} |> Prospect.changeset(attrs) |> Repo.insert()
  end

  def update_prospect(%Prospect{} = prospect, attrs) do
    prospect |> Prospect.changeset(attrs) |> Repo.update()
  end

  def delete_prospect(%Prospect{} = prospect), do: Repo.delete(prospect)

  def change_prospect(%Prospect{} = prospect, attrs \\ %{}),
    do: Prospect.changeset(prospect, attrs)

  def count_prospects_by_status(project_id) do
    Prospect
    |> where([p], p.project_id == ^project_id)
    |> group_by([p], p.status)
    |> select([p], {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## Suppression

  def suppressed?(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.exists?(from s in Suppression, where: s.email == ^normalized)
  end

  def suppressed?(_), do: false

  def list_suppressions do
    Repo.all(from s in Suppression, order_by: [desc: s.inserted_at])
  end

  @doc """
  Adds an address to the global do-not-contact list. Idempotent — re-suppressing
  an address that's already there is a no-op rather than an error, because
  bounce webhooks and manual adds routinely overlap.
  """
  def suppress(email, reason, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{email: email, reason: reason})

    %Suppression{}
    |> Suppression.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :email)
  end

  def delete_suppression(%Suppression{} = suppression), do: Repo.delete(suppression)

  @doc """
  Marks a prospect unsubscribed and adds them to the global suppression list,
  then stops every sequence they're in. This is what the `/u/:token` link runs.
  """
  def unsubscribe_prospect(%Prospect{} = prospect) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {:ok, prospect} =
        prospect
        |> Ecto.Changeset.change(status: "unsubscribed", unsubscribed_at: now)
        |> Repo.update()

      suppress(prospect.email, "unsubscribed", %{project_id: prospect.project_id})
      stop_enrollments(prospect, "unsubscribed")

      prospect
    end)
  end

  @doc "Marks a prospect as having replied and stops their sequences."
  def mark_replied(%Prospect{} = prospect) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {:ok, prospect} =
        prospect
        |> Ecto.Changeset.change(status: "replied", replied_at: now)
        |> Repo.update()

      stop_enrollments(prospect, "replied")
      prospect
    end)
  end

  @doc "Marks a prospect as bounced, suppresses them, and stops their sequences."
  def mark_bounced(%Prospect{} = prospect, notes \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {:ok, prospect} =
        prospect
        |> Ecto.Changeset.change(status: "bounced", bounced_at: now)
        |> Repo.update()

      suppress(prospect.email, "bounced", %{project_id: prospect.project_id, notes: notes})
      stop_enrollments(prospect, "bounced")
      prospect
    end)
  end

  defp stop_enrollments(%Prospect{id: prospect_id}, reason) do
    Enrollment
    |> where([e], e.prospect_id == ^prospect_id and e.status == "active")
    |> Repo.update_all(set: [status: "stopped", stopped_reason: reason, next_send_at: nil])
  end

  ## Sequences

  def list_sequences(project_id) do
    Sequence
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def get_sequence!(id), do: Sequence |> Repo.get!(id) |> Repo.preload([:steps, :project])

  def create_sequence(attrs) do
    %Sequence{} |> Sequence.changeset(attrs) |> Repo.insert()
  end

  def update_sequence(%Sequence{} = sequence, attrs) do
    sequence |> Sequence.changeset(attrs) |> Repo.update()
  end

  def delete_sequence(%Sequence{} = sequence), do: Repo.delete(sequence)

  def change_sequence(%Sequence{} = sequence, attrs \\ %{}),
    do: Sequence.changeset(sequence, attrs)

  @doc """
  Activating is guarded: a sequence with no steps would enroll people and then
  silently never mail them, which looks identical to a broken scheduler.
  """
  def activate_sequence(%Sequence{} = sequence) do
    sequence = Repo.preload(sequence, :steps)

    if sequence.steps == [] do
      {:error, :no_steps}
    else
      update_sequence(sequence, %{status: "active"})
    end
  end

  def pause_sequence(%Sequence{} = sequence), do: update_sequence(sequence, %{status: "paused"})

  @doc """
  Activates a campaign and enrolls the chosen recipients in one go.

  Sending is still the scheduler's job — this only makes people due. That keeps
  the daily cap meaningful: a campaign to 2,000 people at 50/day goes out over
  forty days rather than torching the sending domain in an hour.
  """
  def send_campaign(%Sequence{} = sequence, prospect_ids) do
    with {:ok, sequence} <- activate_sequence(sequence),
         {:ok, result} <- enroll_prospects(sequence, prospect_ids) do
      {:ok, result}
    end
  end

  @doc "Sent/opened/clicked for one campaign — the numbers on its own page."
  def campaign_stats(sequence_id) do
    base =
      from(m in Message,
        join: e in assoc(m, :enrollment),
        where: e.sequence_id == ^sequence_id
      )

    sent = Repo.one(from [m, _e] in base, where: m.status == "sent", select: count(m.id))

    opened =
      Repo.one(from [m, _e] in base, where: not is_nil(m.first_opened_at), select: count(m.id))

    clicked =
      Repo.one(
        from [m, _e] in base,
          join: l in assoc(m, :tracked_links),
          where: l.click_count > 0,
          select: count(m.id, :distinct)
      )

    %{sent: sent, opened: opened, clicked: clicked}
  end

  ## Sequence steps

  def get_step!(id), do: Repo.get!(SequenceStep, id)

  @doc "Appends a step to the end of a sequence."
  def create_step(%Sequence{} = sequence, attrs) do
    position = next_step_position(sequence.id)

    %SequenceStep{}
    |> SequenceStep.changeset(
      Map.merge(attrs, %{"sequence_id" => sequence.id, "position" => position})
    )
    |> Repo.insert()
  end

  defp next_step_position(sequence_id) do
    max =
      SequenceStep
      |> where([s], s.sequence_id == ^sequence_id)
      |> select([s], max(s.position))
      |> Repo.one()

    (max || 0) + 1
  end

  def update_step(%SequenceStep{} = step, attrs) do
    step |> SequenceStep.changeset(attrs) |> Repo.update()
  end

  def change_step(%SequenceStep{} = step, attrs \\ %{}),
    do: SequenceStep.changeset(step, attrs)

  @doc """
  Deletes a step and closes the gap in `position`, so positions stay a dense
  1..n run. The unique index on (sequence_id, position) means the renumber has
  to happen in one statement rather than row by row.
  """
  def delete_step(%SequenceStep{} = step) do
    Repo.transaction(fn ->
      Repo.delete!(step)

      from(s in SequenceStep,
        where: s.sequence_id == ^step.sequence_id and s.position > ^step.position
      )
      |> Repo.update_all(inc: [position: -1])

      :ok
    end)
  end

  ## Enrollments

  @doc """
  Enrolls prospects into a sequence, skipping anyone who can't be mailed.

  Returns `{:ok, %{enrolled: n, skipped: n}}`. Skipping rather than erroring is
  deliberate: enrolling a 500-row list shouldn't fail because three of them
  unsubscribed last month.
  """
  def enroll_prospects(%Sequence{} = sequence, prospect_ids) when is_list(prospect_ids) do
    sequence = Repo.preload(sequence, :project)

    prospects =
      Prospect
      |> where([p], p.id in ^prospect_ids)
      |> Repo.all()

    {enrolled, skipped} =
      Enum.reduce(prospects, {0, 0}, fn prospect, {ok, skip} ->
        case enroll_prospect(sequence, prospect) do
          {:ok, _} -> {ok + 1, skip}
          _ -> {ok, skip + 1}
        end
      end)

    {:ok, %{enrolled: enrolled, skipped: skipped}}
  end

  @doc """
  Enrolls one prospect. The first step's send time is computed now so the
  scheduler only ever has to compare `next_send_at` against the clock.
  """
  def enroll_prospect(%Sequence{} = sequence, %Prospect{} = prospect) do
    sequence = Repo.preload(sequence, [:project, :steps])

    cond do
      not Prospect.mailable?(prospect) ->
        {:error, :not_mailable}

      suppressed?(prospect.email) ->
        {:error, :suppressed}

      sequence.steps == [] ->
        {:error, :no_steps}

      true ->
        first_step = List.first(sequence.steps)

        send_at =
          Window.next_open_slot(
            sequence,
            sequence.project,
            DateTime.utc_now() |> DateTime.add(first_step.delay_days, :day)
          )

        %Enrollment{}
        |> Enrollment.changeset(%{
          sequence_id: sequence.id,
          prospect_id: prospect.id,
          status: "active",
          current_position: 0,
          next_send_at: send_at
        })
        |> Repo.insert()
    end
  end

  def list_enrollments(sequence_id) do
    Enrollment
    |> where([e], e.sequence_id == ^sequence_id)
    |> order_by([e], asc: e.next_send_at)
    |> preload(:prospect)
    |> Repo.all()
  end

  def get_enrollment!(id),
    do: Enrollment |> Repo.get!(id) |> Repo.preload([:prospect, sequence: [:project, :steps]])

  def stop_enrollment(%Enrollment{} = enrollment, reason \\ "manual") do
    enrollment
    |> Ecto.Changeset.change(status: "stopped", stopped_reason: reason, next_send_at: nil)
    |> Repo.update()
  end

  def count_enrollments_by_status(sequence_id) do
    Enrollment
    |> where([e], e.sequence_id == ^sequence_id)
    |> group_by([e], e.status)
    |> select([e], {e.status, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## Messages

  def list_messages(project_id, limit \\ 100) do
    Message
    |> where([m], m.project_id == ^project_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> preload([:prospect, :tracked_links])
    |> Repo.all()
  end

  def get_message!(id),
    do: Message |> Repo.get!(id) |> Repo.preload([:prospect, :project, :tracked_links])

  def list_messages_for_prospect(prospect_id) do
    Message
    |> where([m], m.prospect_id == ^prospect_id)
    |> order_by([m], desc: m.inserted_at)
    |> preload(:tracked_links)
    |> Repo.all()
  end

  ## Global search — backs the ⌘K palette

  @doc """
  Prospects matching `q` across *every* project.

  The palette is deliberately not project-scoped: you usually remember the
  person's name, not which idea you filed them under.
  """
  def search_prospects(q, limit \\ 8) do
    like = "%#{String.trim(q)}%"

    Prospect
    |> where(
      [p],
      ilike(type(p.email, :string), ^like) or ilike(p.first_name, ^like) or
        ilike(p.last_name, ^like) or ilike(p.company, ^like)
    )
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def search_sequences(q, limit \\ 8) do
    like = "%#{String.trim(q)}%"

    Sequence
    |> where([s], ilike(s.name, ^like))
    |> order_by([s], asc: s.name)
    |> limit(^limit)
    |> Repo.all()
  end

  def search_projects(q, limit \\ 8) do
    like = "%#{String.trim(q)}%"

    Project
    |> where([p], ilike(p.name, ^like) or ilike(type(p.from_email, :string), ^like))
    |> order_by([p], asc: p.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Headline counters for a project's dashboard card."
  def project_stats(project_id) do
    sent =
      Message
      |> where([m], m.project_id == ^project_id and m.status == "sent")
      |> select([m], count(m.id))
      |> Repo.one()

    opened =
      Message
      |> where([m], m.project_id == ^project_id and not is_nil(m.first_opened_at))
      |> select([m], count(m.id))
      |> Repo.one()

    clicked =
      from(m in Message,
        join: l in assoc(m, :tracked_links),
        where: m.project_id == ^project_id and l.click_count > 0,
        select: count(m.id, :distinct)
      )
      |> Repo.one()

    %{
      prospects:
        Repo.one(from p in Prospect, where: p.project_id == ^project_id, select: count(p.id)),
      sent: sent,
      opened: opened,
      clicked: clicked
    }
  end
end
