defmodule ColdForge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ColdForgeWeb.Telemetry,
      ColdForge.Repo,
      {DNSCluster, query: Application.get_env(:cold_forge, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ColdForge.PubSub},
      {Oban, Application.fetch_env!(:cold_forge, Oban)},
      # Start a worker by calling: ColdForge.Worker.start_link(arg)
      # {ColdForge.Worker, arg},
      # Start to serve requests, typically the last entry
      ColdForgeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ColdForge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ColdForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
