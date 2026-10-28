defmodule ColdForge.Workers.ForwardReply do
  @moduledoc """
  Sends a reply on to a person's own inbox.

  Replies come back to the sending domain so the app can see them and stop the
  drip; without this they would land there and nowhere else. The copy is sent
  from the project's own address — the only domain SES will send as — with
  Reply-To set to whoever wrote, so answering it from the inbox answers them.

  A job rather than a call in the request: SNS waits on the response, and a
  slow or failed send should be retried, not lose the reply.
  """
  use Oban.Worker, queue: :sending, max_attempts: 5

  alias ColdForge.{Mailer, Outreach}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id} = args}) do
    project = Outreach.get_project!(project_id)

    case present(project.forward_replies_to) do
      nil ->
        :ok

      to ->
        email =
          Swoosh.Email.new()
          |> Swoosh.Email.to(to)
          |> Swoosh.Email.from({"#{args["from"]} via Cold Forge", project.from_email})
          |> Swoosh.Email.reply_to(args["from"])
          |> Swoosh.Email.subject(subject(args["subject"]))
          |> Swoosh.Email.text_body(body(args, project))

        case Mailer.deliver(email) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp subject(nil), do: "Reply to your outreach"
  defp subject(subject), do: "Reply: " <> String.replace_prefix(subject, "Re: ", "")

  defp body(args, project) do
    link =
      case args["prospect_id"] do
        nil ->
          "They aren't one of your prospects in #{project.name}."

        id ->
          "Their drip has stopped. Prospect: " <>
            ColdForgeWeb.Endpoint.url() <> "/admin/p/#{project.id}/prospects/#{id}/edit"
      end

    """
    #{args["from"]} replied:

    #{args["body"] || "(no text)"}

    ---
    #{link}
    Reply to this email to answer them directly.
    """
  end

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
