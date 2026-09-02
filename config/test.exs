import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cold_forge, ColdForge.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cold_forge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Capped rather than `schedulers_online() * 2`: this machine reports 36
  # schedulers, which asks Postgres for 72 connections against a default
  # max_connections of 100 and fails to connect partway through a run.
  pool_size: min(System.schedulers_online() * 2, 16)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cold_forge, ColdForgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "RMnA1LCTeZPyl1o+NODxb13mpndKVu6Emx5BR6etuiUF7QcuqRlV3OK7qfWdeeyc",
  server: false

# In test we don't send emails
config :cold_forge, ColdForge.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# A known secret so the inbound endpoint can be exercised.
config :cold_forge, :inbound_token, "test-inbound-token"

# `:manual` stops queues and cron, so no background send fires in the middle of
# an assertion. The PG notifier keeps Oban off a second Postgres connection per
# test process, which the default (Postgres) notifier opens.
config :cold_forge, Oban, testing: :manual, notifier: Oban.Notifiers.PG

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
