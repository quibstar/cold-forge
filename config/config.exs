# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cold_forge, :scopes,
  user: [
    default: true,
    module: ColdForge.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: ColdForge.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :cold_forge,
  ecto_repos: [ColdForge.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :cold_forge, ColdForgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ColdForgeWeb.ErrorHTML, json: ColdForgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ColdForge.PubSub,
  live_view: [signing_salt: "Mdh7hGRx"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
# UUIDv7 primary keys everywhere (see `ColdForge.UUIDv7`). Set on the repo so a
# new migration cannot quietly go back to bigserial and leave one table unable
# to be referenced by the rest.
config :cold_forge, ColdForge.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [column: :id, type: :binary_id]

config :cold_forge, ColdForge.Mailer, adapter: Swoosh.Adapters.Local

# The SES adapter (see config/runtime.exs) builds a raw MIME message with
# `:gen_smtp` and posts it over HTTP, so Swoosh needs an API client. Req is
# already a dependency and needs no supervisor of its own. Overridden to
# `false` in test.exs, where nothing leaves the machine.
config :swoosh, :api_client, Swoosh.ApiClient.Req

# Send windows are expressed in a project's own timezone ("no mail before 8am
# their time"), which needs a real tz database rather than UTC offsets.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Oban runs the drip: one job scans for due enrollments, one job sends a single
# message. `sending` is capped low on purpose — cold mail that leaves in a burst
# looks like a burst.
config :cold_forge, Oban,
  repo: ColdForge.Repo,
  queues: [scheduler: 1, sending: 3],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", ColdForge.Workers.CampaignScheduler}
     ]}
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cold_forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  cold_forge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
