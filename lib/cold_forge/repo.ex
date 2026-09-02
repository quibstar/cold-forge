defmodule ColdForge.Repo do
  use Ecto.Repo,
    otp_app: :cold_forge,
    adapter: Ecto.Adapters.Postgres
end
