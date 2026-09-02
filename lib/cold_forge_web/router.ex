defmodule ColdForgeWeb.Router do
  use ColdForgeWeb, :router

  import ColdForgeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ColdForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The endpoints that appear inside outgoing mail. Deliberately *not*
  # `:protect_from_forgery` — RFC 8058 one-click unsubscribe is POSTed by the
  # recipient's mail client, which has no CSRF token to send. Nothing here
  # touches a signed-in session, so there's no session to forge against.
  pipeline :public_tracking do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_root_layout, html: {ColdForgeWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  scope "/", ColdForgeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", ColdForgeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cold_forge, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ColdForgeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Tracking endpoints — the URLs baked into outgoing email

  scope "/", ColdForgeWeb do
    pipe_through :public_tracking

    get "/c/:token", TrackingController, :click
    get "/o/:token", TrackingController, :open
    get "/u/:token", TrackingController, :unsubscribe_form
    post "/u/:token", TrackingController, :unsubscribe
  end

  ## Admin — the whole application. Cold Forge has exactly one operator, so the
  ## signed-in user *is* the admin; there's no second identity to model.

  scope "/admin", ColdForgeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :admin,
      on_mount: [
        {ColdForgeWeb.UserAuth, :require_authenticated},
        ColdForgeWeb.AdminLive.Nav
      ],
      layout: {ColdForgeWeb.Layouts, :admin} do
      live "/", AdminLive.Dashboard, :index

      live "/projects", AdminLive.Projects, :index
      live "/projects/new", AdminLive.Projects, :new
      live "/projects/:id/edit", AdminLive.Projects, :edit

      live "/suppressions", AdminLive.Suppressions, :index
      live "/guide", AdminLive.Guide, :index

      # A project is one place with three views. Campaigns is the project root
      # rather than a `/campaigns` child, because it's what you came for.
      live "/p/:project_id", AdminLive.Campaigns, :index
      live "/p/:project_id/campaigns/new", AdminLive.Campaigns, :new
      live "/p/:project_id/campaigns/:id", AdminLive.CampaignShow, :show
      live "/p/:project_id/campaigns/:id/people", AdminLive.CampaignShow, :people
      live "/p/:project_id/campaigns/:id/emails/new", AdminLive.CampaignShow, :new_email
      live "/p/:project_id/campaigns/:id/emails/:step_id", AdminLive.CampaignShow, :edit_email

      live "/p/:project_id/prospects", AdminLive.Prospects, :index
      live "/p/:project_id/prospects/new", AdminLive.Prospects, :new
      live "/p/:project_id/prospects/import", AdminLive.Import, :new
      live "/p/:project_id/prospects/:id/edit", AdminLive.Prospects, :edit

      live "/p/:project_id/activity", AdminLive.Messages, :index
      live "/p/:project_id/activity/:id", AdminLive.Messages, :show
    end
  end

  ## Authentication routes

  scope "/", ColdForgeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ColdForgeWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ColdForgeWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ColdForgeWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
