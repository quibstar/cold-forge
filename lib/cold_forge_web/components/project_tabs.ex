defmodule ColdForgeWeb.ProjectTabs do
  @moduledoc """
  The tabs across the top of one campaign: its searches, people, email
  sequences, calls, postcards, replies and activity.

  Outside a campaign this renders nothing. A project's own pages — its
  campaigns, and what they all share (surveys, flyers, call scripts) — are in
  the sidebar under the project's name, so the campaigns page shows campaigns
  rather than a row of tabs above them.
  """
  use ColdForgeWeb, :html

  attr :project, :map, required: true
  attr :market, :map, default: nil
  attr :current_path, :string, default: nil

  def project_tabs(assigns) do
    ~H"""
    <%!-- Which campaign you're in, small: the page title says what you're
    looking at ("Calls"), this says whose. --%>
    <p :if={@market} id="market-context" class="text-sm text-base-content/60 mb-2">
      <.link navigate={~p"/admin/p/#{@project.id}"} class="link link-hover">
        {@project.name} campaigns
      </.link>
      <span class="mx-1">/</span>
      <span class="font-medium text-base-content">{@market.name}</span>
    </p>
    <%!-- `tabs-border`, not `tabs-bordered` — the latter is daisyUI 4 syntax and
    silently does nothing on the vendored v5 build, which leaves the active tab
    with no underline at all. --%>
    <div :if={@market} role="tablist" class="tabs tabs-border mb-6 flex-nowrap overflow-x-auto">
      <.link
        :for={{label, path, icon} <- tabs(@project, @market)}
        role="tab"
        navigate={path}
        aria-selected={active?(@current_path, path, root(@project, @market))}
        class={[
          "tab gap-2 shrink-0",
          if(active?(@current_path, path, root(@project, @market)),
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

  defp root(project, market), do: ~p"/admin/p/#{project.id}/c/#{market.id}"

  defp tabs(project, market) do
    base = ~p"/admin/p/#{project.id}/c/#{market.id}"

    [
      {"Overview", base, "hero-chart-bar"},
      {"Sourcing", base <> "/sourcing", "hero-magnifying-glass"},
      {"People", base <> "/prospects", "hero-users"},
      {"Emails", base <> "/campaigns", "hero-paper-airplane"},
      {"Calls", base <> "/calls", "hero-phone"},
      {"Postcards", base <> "/postcards", "hero-envelope-open"},
      {"Replies", base <> "/replies", "hero-inbox-arrow-down"},
      {"Activity", base <> "/activity", "hero-envelope"}
    ]
  end

  # Overview is the campaign's root, so it would prefix-match every other tab;
  # it only lights for itself and its rename form.
  defp active?(nil, _path, _root), do: false

  defp active?(current, path, root) when path == root,
    do: current in [root, root <> "/edit"]

  defp active?(current, path, _root), do: String.starts_with?(current, path)
end
