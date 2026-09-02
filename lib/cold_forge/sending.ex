defmodule ColdForge.Sending do
  @moduledoc """
  Builds and delivers a single email.

  Everything that decides *whether* to send lives in `check_sendable/2` and runs
  immediately before delivery rather than when the job was queued — an
  enrollment scheduled three days ago may have been unsubscribed since.
  """

  import Ecto.Query, warn: false

  alias ColdForge.Mailer
  alias ColdForge.Outreach
  alias ColdForge.Outreach.{Enrollment, Message, Project, Prospect, CampaignStep}
  alias ColdForge.Repo
  alias ColdForge.Sending.Renderer

  @doc """
  Renders, persists and delivers the message for one step.

  The message row is inserted *before* delivery, so a send that crashes leaves a
  `pending` row to investigate rather than no trace at all. Tracked links need
  that row's id, which is why the body is written twice: once raw, then again
  with tokens substituted.
  """
  def deliver_step(
        %Prospect{} = prospect,
        %CampaignStep{} = step,
        %Project{} = project,
        opts \\ []
      ) do
    enrollment_id = opts[:enrollment_id]
    branded? = Keyword.get(opts, :branded, false)
    question = opts[:question]
    campaign = opts[:campaign]

    with :ok <- check_sendable(prospect, project) do
      base_url = base_url()
      rendered = Renderer.render_step(step, prospect, project, campaign)

      Repo.transaction(fn ->
        message =
          %Message{}
          |> Message.changeset(%{
            project_id: project.id,
            prospect_id: prospect.id,
            enrollment_id: enrollment_id,
            campaign_step_id: step.id,
            subject: rendered.subject,
            body: rendered.body,
            status: "pending"
          })
          |> Repo.insert!()

        final_body =
          rendered.body
          # Before rewrite_links: the /a/ URLs it produces point back at Cold
          # Forge, and rewrite_links leaves our own links alone.
          |> Renderer.render_survey(message, question, prospect, base_url)
          |> Renderer.rewrite_links(message, base_url)
          |> Renderer.append_footer(prospect, project, base_url)

        # Our own Message-ID, set before delivery so a reply quoting it in
        # In-Reply-To names this exact send. The provider's id never appears in
        # a reply, so it cannot serve here.
        message =
          message
          |> Ecto.Changeset.change(
            body: final_body,
            rfc_message_id: rfc_message_id(message, project)
          )
          |> Repo.update!()

        case deliver(message, prospect, project, final_body, base_url, branded?) do
          {:ok, provider_id} ->
            mark_sent(message, provider_id)

          {:error, reason} ->
            # Rolling back would delete the evidence, so the failure is recorded
            # on the row and the transaction still commits.
            mark_failed(message, reason)
        end
      end)
    end
  end

  @doc """
  Every reason not to send, checked at delivery time.

  Suppression is checked against the global list *and* the prospect's own
  status: the two can disagree if a row was edited directly.
  """
  def check_sendable(%Prospect{} = prospect, %Project{} = project) do
    cond do
      not project.active -> {:error, :project_inactive}
      not Prospect.mailable?(prospect) -> {:error, :prospect_not_mailable}
      Outreach.suppressed?(prospect.email) -> {:error, :suppressed}
      true -> :ok
    end
  end

  defp deliver(message, prospect, project, body, base_url, branded?) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to({Prospect.display_name(prospect), prospect.email})
      |> Swoosh.Email.from({project.from_name, project.from_email})
      |> Swoosh.Email.subject(message.subject)
      |> Swoosh.Email.text_body(body)
      |> Swoosh.Email.html_body(Renderer.to_html(body, message, base_url, project, branded?))
      |> maybe_reply_to(project)
      # RFC 8058: mail clients render a native "Unsubscribe" button from these,
      # which keeps people from reaching for "mark as spam" instead.
      |> Swoosh.Email.header(
        "List-Unsubscribe",
        "<#{Renderer.unsubscribe_url(base_url, prospect)}>"
      )
      |> Swoosh.Email.header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
      |> Swoosh.Email.header("Message-ID", "<#{message.rfc_message_id}>")

    case Mailer.deliver(email) do
      {:ok, response} -> {:ok, provider_message_id(response)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Domain-qualified with the sending address's own domain: a Message-ID whose
  # right-hand side doesn't resolve to the sender is a spam signal, and the
  # local part is the message's id so a reply is traceable without a lookup
  # table.
  defp rfc_message_id(message, project) do
    domain =
      case String.split(project.from_email, "@") do
        [_local, domain] -> domain
        _ -> "cold-forge.invalid"
      end

    "#{message.id}@#{domain}"
  end

  defp maybe_reply_to(email, %Project{reply_to: nil}), do: email
  defp maybe_reply_to(email, %Project{reply_to: ""}), do: email

  defp maybe_reply_to(email, %Project{reply_to: reply_to}),
    do: Swoosh.Email.reply_to(email, reply_to)

  # Adapters disagree on the shape of a success response; SES returns a map with
  # an id, the local adapter returns something else entirely.
  defp provider_message_id(%{id: id}), do: to_string(id)
  defp provider_message_id(%{"MessageId" => id}), do: to_string(id)
  defp provider_message_id(_), do: nil

  defp mark_sent(message, provider_id) do
    message
    |> Ecto.Changeset.change(
      status: "sent",
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
      provider_message_id: provider_id
    )
    |> Repo.update!()
  end

  defp mark_failed(message, reason) do
    message
    |> Ecto.Changeset.change(
      status: "failed",
      failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: reason
    )
    |> Repo.update!()
  end

  @doc """
  Sends the rendered email to `to_email` so the operator can see it in a real
  inbox.

  Deliberately writes no `messages` row and no tracked links: a test send is not
  something the prospect did, and counting it would corrupt the numbers you use
  to judge the campaign. Link tokens are the preview placeholders, so clicking
  one in a test goes nowhere — that's the tradeoff for not polluting stats.
  """
  def deliver_test(
        to_email,
        subject,
        body,
        %Prospect{} = prospect,
        %Project{} = project,
        opts \\ []
      ) do
    branded? = Keyword.get(opts, :branded, false)
    preview = Renderer.preview_message(subject, body, prospect, project, branded: branded?)

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(to_email)
      |> Swoosh.Email.from({project.from_name, project.from_email})
      |> Swoosh.Email.subject("[test] " <> preview.subject)
      |> Swoosh.Email.text_body(preview.text)
      |> Swoosh.Email.html_body(preview.html)
      |> maybe_reply_to(project)

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Advances an enrollment to its next step, or completes it when the steps run
  out. Called after a successful send.
  """
  def advance_enrollment(%Enrollment{} = enrollment) do
    enrollment = Repo.preload(enrollment, campaign: [:project, :steps])
    next_position = enrollment.current_position + 1
    next_step = Enum.find(enrollment.campaign.steps, &(&1.position == next_position + 1))

    if next_step do
      send_at =
        ColdForge.Sending.Window.next_open_slot(
          enrollment.campaign,
          enrollment.campaign.project,
          DateTime.utc_now() |> DateTime.add(next_step.delay_days, :day)
        )

      enrollment
      |> Ecto.Changeset.change(current_position: next_position, next_send_at: send_at)
      |> Repo.update()
    else
      enrollment
      |> Ecto.Changeset.change(
        current_position: next_position,
        status: "completed",
        next_send_at: nil,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update()
    end
  end

  @doc """
  The public origin used to build tracked links.

  Read from the endpoint rather than hardcoded, because these URLs are baked
  into mail that outlives any given deploy — a wrong value here is a dead link
  in somebody's inbox.
  """
  def base_url do
    ColdForgeWeb.Endpoint.url()
  end
end
