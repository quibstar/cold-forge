defmodule ColdForgeWeb.AdminLive.Replies do
  @moduledoc """
  What came back.

  The reply text is shown in full rather than as a subject line, because the
  whole point of the outreach is the conversation, and a list of names tells
  you nothing about what anybody said.
  """
  use ColdForgeWeb, :live_view

  import ColdForgeWeb.ProjectTabs

  alias ColdForge.Inbox
  alias ColdForge.Outreach.Prospect

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:project_id, project_id)
     |> assign(:page_title, socket.assigns.current_project.name)
     |> assign(:breadcrumbs, [{"Projects", ~p"/admin/projects"}])
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:replies, Inbox.list_replies(socket.assigns.project_id))
    |> assign(:people, Inbox.replied_count(socket.assigns.project_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.project_tabs project={@current_project} current_path={@current_path} />

    <div :if={@replies == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-16">
        <.icon name="hero-inbox" class="size-10 text-base-content/30" />
        <h2 class="card-title mt-2">Nothing back yet</h2>
        <p class="text-base-content/60 max-w-md">
          Replies land here once your mail provider is forwarding them. Until
          then you can still mark someone as replied by hand from the prospect
          list. <.link navigate={~p"/admin/guide"} class="link">How to set it up</.link>
        </p>
      </div>
    </div>

    <div :if={@replies != []}>
      <p class="text-sm text-base-content/60 mb-4">
        {@people} {if @people == 1, do: "person has", else: "people have"} written back.
      </p>

      <div class="space-y-3">
        <div :for={reply <- @replies} class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <.link
                  navigate={~p"/admin/p/#{@project_id}/prospects/#{reply.prospect_id}/edit"}
                  class="font-medium hover:text-primary"
                >
                  {Prospect.display_name(reply.prospect)}
                </.link>
                <div class="text-xs text-base-content/50">
                  {reply.from_email} · {Calendar.strftime(reply.received_at, "%b %-d, %H:%M")}
                </div>
              </div>

              <div class="flex items-center gap-2 shrink-0">
                <%!-- An address match says who wrote, not what they answered.
                Worth flagging, because a run of them usually means the
                Message-ID header isn't surviving the round trip. --%>
                <span
                  :if={reply.matched_by == "address"}
                  class="badge badge-sm badge-ghost"
                  title="Matched on the sender's address — not tied to a specific email"
                >
                  by address
                </span>
                <span :if={reply.automated} class="badge badge-sm badge-warning">
                  automated
                </span>
              </div>
            </div>

            <div :if={reply.subject} class="text-sm font-medium mt-2">{reply.subject}</div>
            <p
              :if={reply.body not in [nil, ""]}
              class="text-sm text-base-content/70 whitespace-pre-line mt-1"
            >
              {reply.body}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
