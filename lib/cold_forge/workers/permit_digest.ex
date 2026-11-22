defmodule ColdForge.Workers.PermitDigest do
  @moduledoc """
  Weekly: tells each project's owner what its permit sources found, with a link
  to the page where one click adds them and starts the drip.

  The review step, kept short on purpose. The weekly scan finds and checks on
  its own; the decision to email a new batch stays with a person, a minute a
  week, because a bad batch on the shared sending domain costs every project.

  Sent to the project's `forward_replies_to`, the inbox replies already go to.
  Nothing is sent when there's nothing new.
  """
  use Oban.Worker, queue: :sending, max_attempts: 3

  alias ColdForge.{Mailer, Outreach, Sourcing}

  @impl Oban.Worker
  def perform(_job) do
    Sourcing.list_sources()
    |> Enum.filter(&(&1.active and &1.provider == "permits"))
    |> Enum.group_by(& &1.project_id)
    |> Enum.each(fn {project_id, sources} ->
      digest(Outreach.get_project!(project_id), sources)
    end)

    :ok
  end

  defp digest(project, sources) do
    lines =
      for source <- sources,
          counts = Sourcing.addable_counts(source),
          counts.email + counts.calls + counts.checking > 0,
          do: {source, counts}

    with to when is_binary(to) and to != "" <- project.forward_replies_to,
         [_ | _] <- lines do
      Swoosh.Email.new()
      |> Swoosh.Email.to(to)
      |> Swoosh.Email.from({"Cold Forge", project.from_email})
      |> Swoosh.Email.subject(subject(project, lines))
      |> Swoosh.Email.text_body(body(project, lines))
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> :ok
    end
  end

  @doc false
  def subject(project, lines) do
    email = lines |> Enum.map(fn {_s, c} -> c.email end) |> Enum.sum()
    "#{project.name}: #{email} new contractors from permits ready to email"
  end

  @doc false
  def body(project, lines) do
    sections =
      Enum.map_join(lines, "\n\n", fn {source, counts} ->
        drip =
          if source.campaign_id,
            do: "One click adds them and starts the drip.",
            else: "This source has no drip set, so Add all makes them prospects only."

        """
        #{source.name}
          #{counts.email} with an email address. #{drip}
          #{counts.calls} with a phone and no email, for the call list.
          #{counts.checking} websites still being checked.
          #{ColdForgeWeb.Endpoint.url()}/admin/p/#{project.id}/sourcing/#{source.id}
        """
      end)

    """
    This week's permit scan for #{project.name}:

    #{sections}
    Nothing is emailed until you click Add all on the page.
    """
  end
end
