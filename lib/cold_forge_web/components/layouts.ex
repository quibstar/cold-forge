defmodule ColdForgeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ColdForgeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://phoenix.hexdocs.pm/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The admin shell: fixed left sidebar, scrollable content, off-canvas drawer on
  mobile. Modelled on the ExteriorPro admin so moving between the two apps
  doesn't mean relearning where anything is.

  Used as a *live_session layout* (`layout: {Layouts, :admin}`), so it renders
  `@inner_content` and receives the LiveView's assigns directly rather than
  declaring its own attrs.
  """
  def admin(assigns) do
    assigns =
      assigns
      |> assign_new(:current_scope, fn -> nil end)
      |> assign_new(:current_path, fn -> nil end)
      |> assign_new(:current_project, fn -> nil end)
      |> assign_new(:page_title, fn -> nil end)
      |> assign_new(:page_subtitle, fn -> nil end)

    ~H"""
    <div class="flex h-screen overflow-hidden bg-base-200">
      <div
        id="sidebar-overlay"
        class="fixed inset-0 z-40 bg-black/50 lg:hidden"
        phx-click={
          JS.remove_class("open", to: "#admin-sidebar")
          |> JS.remove_class("open", to: "#sidebar-overlay")
        }
      />

      <aside
        id="admin-sidebar"
        class="fixed inset-y-0 left-0 z-50 w-64 flex flex-col bg-base-100 border-r border-base-300"
      >
        <div class="flex items-center justify-between px-4 h-16 border-b border-base-300 shrink-0">
          <.link navigate={~p"/admin"} class="flex items-center gap-2 min-w-0">
            <span class="flex items-center justify-center size-9 rounded-lg bg-primary/10 shrink-0">
              <.icon name="hero-fire" class="size-5 text-primary" />
            </span>
            <div class="leading-tight min-w-0">
              <div class="text-sm font-bold logo-color truncate">Cold Forge</div>
              <div class="text-xs text-base-content/50 -mt-0.5">Outreach</div>
            </div>
          </.link>
          <button
            class="lg:hidden flex items-center justify-center size-8 rounded-lg hover:bg-base-200 cursor-pointer"
            phx-click={
              JS.remove_class("open", to: "#admin-sidebar")
              |> JS.remove_class("open", to: "#sidebar-overlay")
            }
            aria-label="Close navigation"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto px-3 py-4 space-y-1">
          <.nav_link
            navigate={~p"/admin"}
            icon="hero-home"
            active={nav_active(@current_path, "/admin")}
          >
            Dashboard
          </.nav_link>
          <.nav_link
            navigate={~p"/admin/projects"}
            icon="hero-squares-2x2"
            active={nav_active(@current_path, "/admin/projects")}
          >
            Projects
          </.nav_link>
          <.nav_link
            navigate={~p"/admin/suppressions"}
            icon="hero-no-symbol"
            active={nav_active(@current_path, "/admin/suppressions")}
          >
            Do not contact
          </.nav_link>
          <.nav_link
            navigate={~p"/admin/guide"}
            icon="hero-book-open"
            active={nav_active(@current_path, "/admin/guide")}
          >
            How this works
          </.nav_link>

          <%!-- Prospects, sequences and activity are meaningless without a
          project to scope them to, so this section only appears once one is
          selected — rather than showing links that 404. --%>
          <div :if={@current_project}>
            <.nav_section>{@current_project.name}</.nav_section>
            <.nav_link
              navigate={~p"/admin/p/#{@current_project.id}/campaigns"}
              icon="hero-paper-airplane"
              active={nav_active(@current_path, "/admin/p/#{@current_project.id}/campaigns")}
            >
              Campaigns
            </.nav_link>
            <.nav_link
              navigate={~p"/admin/p/#{@current_project.id}/prospects"}
              icon="hero-users"
              active={nav_active(@current_path, "/admin/p/#{@current_project.id}/prospects")}
            >
              Prospects
            </.nav_link>
            <.nav_link
              navigate={~p"/admin/p/#{@current_project.id}/messages"}
              icon="hero-envelope"
              active={nav_active(@current_path, "/admin/p/#{@current_project.id}/messages")}
            >
              Activity
            </.nav_link>
          </div>
        </nav>

        <%!-- `dropdown-top` so the menu opens upward — this sits at the very
        bottom of the viewport, and a downward menu would be clipped. --%>
        <div
          :if={@current_scope && @current_scope.user}
          class="px-3 py-3 border-t border-base-300 shrink-0"
        >
          <div class="dropdown dropdown-top w-full">
            <div
              tabindex="0"
              role="button"
              class="flex items-center gap-3 w-full rounded-lg p-2 hover:bg-base-200 cursor-pointer"
            >
              <div class="size-9 rounded-full bg-primary text-primary-content flex items-center justify-center text-sm font-semibold shrink-0">
                {String.upcase(String.at(@current_scope.user.email, 0) || "?")}
              </div>
              <div class="flex-1 min-w-0 text-left">
                <div class="text-sm font-medium text-base-content truncate">
                  {@current_scope.user.email}
                </div>
                <div class="text-xs text-base-content/60 truncate">Operator</div>
              </div>
              <.icon name="hero-chevron-up-down" class="size-4 text-base-content/50 shrink-0" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu w-56 mb-2 p-2 shadow-lg bg-base-100 rounded-box border border-base-300"
            >
              <li>
                <.link navigate={~p"/users/settings"}>
                  <.icon name="hero-cog-8-tooth" class="size-4" /> Account settings
                </.link>
              </li>
              <li>
                <.link navigate={~p"/admin/projects"}>
                  <.icon name="hero-squares-2x2" class="size-4" /> Projects
                </.link>
              </li>
              <li>
                <.link navigate={~p"/admin/suppressions"}>
                  <.icon name="hero-no-symbol" class="size-4" /> Do not contact
                </.link>
              </li>
              <li><hr class="border-base-300 my-1" /></li>
              <li>
                <.link href={~p"/users/log-out"} method="delete">
                  <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Log out
                </.link>
              </li>
            </ul>
          </div>

          <div class="mt-2 flex justify-center">
            <.theme_toggle />
          </div>
        </div>
      </aside>

      <div class="flex flex-col flex-1 min-w-0 lg:ml-64">
        <%!-- Sticky header: the page's identity on the left, global search on
        the right. The title lives here rather than in the scroll area so it
        stays visible on a long prospect list. --%>
        <header class="sticky top-0 z-30 flex items-center gap-4 px-4 sm:px-6 h-16 bg-base-100 border-b border-base-300 shrink-0">
          <button
            id="sidebar-toggle"
            class="lg:hidden flex items-center justify-center size-9 rounded-lg hover:bg-base-200 cursor-pointer shrink-0"
            phx-click={
              JS.add_class("open", to: "#admin-sidebar")
              |> JS.add_class("open", to: "#sidebar-overlay")
            }
            aria-label="Open navigation"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>

          <div :if={@page_title} class="min-w-0">
            <h1 class="text-2xl font-bold text-base-content truncate">{@page_title}</h1>
            <p
              :if={@page_subtitle not in [nil, ""]}
              class="text-sm text-base-content/60 mt-0.5 truncate"
            >
              {@page_subtitle}
            </p>
          </div>

          <div class="flex-1"></div>

          <%!-- Global command palette trigger (⌘K). Opens the SearchPalette
          rendered below, outside this header — the header is its own stacking
          context, so a modal inside it could never cover the sidebar. --%>
          <button
            type="button"
            phx-click="open"
            phx-target="#search-palette"
            class="hidden sm:flex items-center gap-2 rounded-lg border border-base-300 px-3 py-1.5 text-sm text-base-content/50 hover:border-base-content/30 hover:text-base-content/80 transition-colors shrink-0"
          >
            <.icon name="hero-magnifying-glass" class="size-4" />
            <span>Search</span>
            <kbd class="rounded border border-base-300 px-1.5 py-0.5 text-[10px] leading-none">
              ⌘K
            </kbd>
          </button>

          <button
            type="button"
            phx-click="open"
            phx-target="#search-palette"
            class="sm:hidden flex items-center justify-center size-9 rounded-lg hover:bg-base-200 cursor-pointer shrink-0"
            aria-label="Search"
          >
            <.icon name="hero-magnifying-glass" class="size-5" />
          </button>
        </header>

        <main class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div class="max-w-7xl mx-auto">
            <.flash_group flash={@flash} />
            {@inner_content}
          </div>
        </main>
      </div>

      <.live_component module={ColdForgeWeb.SearchPalette} id="search-palette" />
    </div>
    """
  end

  # `/admin` and `/admin/projects` would otherwise prefix-match deeper paths and
  # light up when you're somewhere else entirely.
  defp nav_active(nil, _path), do: false
  defp nav_active(current, "/admin"), do: current == "/admin"
  defp nav_active(current, "/admin/projects"), do: String.starts_with?(current, "/admin/projects")
  defp nav_active(current, path), do: String.starts_with?(current, path)

  slot :inner_block, required: true

  defp nav_section(assigns) do
    ~H"""
    <p class="px-3 pt-4 pb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "group flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/80 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={[
          "size-5 shrink-0",
          if(@active, do: "text-primary", else: "text-base-content/60 group-hover:text-base-content")
        ]}
      />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
