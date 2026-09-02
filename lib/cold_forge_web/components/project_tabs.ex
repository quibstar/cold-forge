defmodule ColdForgeWeb.ProjectTabs do
  @moduledoc """
  What a project contains: its campaigns, its surveys, its people, and what has
  actually gone out.

  Rendered at the top of each of those screens so a project reads as one place
  with three views, rather than three unrelated destinations that happen to
  share a URL prefix.
  """
  use ColdForgeWeb, :html

  attr :project, :map, required: true
  attr :current_path, :string, default: nil

  def project_tabs(assigns) do
    ~H"""
    <%!-- `tabs-border`, not `tabs-bordered` — the latter is daisyUI 4 syntax and
    silently does nothing on the vendored v5 build, which leaves the active tab
    with no underline at all. --%>
    <div role="tablist" class="tabs tabs-border mb-6">
      <.link
        :for={{label, path, icon} <- tabs(@project)}
        role="tab"
        navigate={path}
        aria-selected={active?(@current_path, path, @project)}
        class={[
          "tab gap-2",
          if(active?(@current_path, path, @project),
            do: "tab-active text-primary font-medium",
            else: "text-base-content/60"
          )
        ]}
      >
        <.icon name={icon} class="size-4" />
        {label}
      </.link>
    </div>
    """
  end

  defp tabs(project) do
    [
      {"Campaigns", ~p"/admin/p/#{project.id}", "hero-paper-airplane"},
      {"Surveys", ~p"/admin/p/#{project.id}/surveys", "hero-clipboard-document-list"},
      {"Prospects", ~p"/admin/p/#{project.id}/prospects", "hero-users"},
      {"Activity", ~p"/admin/p/#{project.id}/activity", "hero-envelope"}
    ]
  end

  # The campaigns tab is the project root, so it would prefix-match the other
  # two. It stays lit for anything campaign-related instead — including the
  # per-campaign pages, which live under this tab conceptually.
  defp active?(nil, _path, _project), do: false

  defp active?(current, path, project) do
    root = ~p"/admin/p/#{project.id}"

    if path == root do
      current == root or String.starts_with?(current, root <> "/campaigns")
    else
      String.starts_with?(current, path)
    end
  end
end
