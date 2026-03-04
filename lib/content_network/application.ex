defmodule ContentNetwork.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ContentNetworkWeb.Telemetry,
      ContentNetwork.Repo,
      {DNSCluster, query: Application.get_env(:content_network, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ContentNetwork.PubSub},
      {Registry, keys: :unique, name: ContentNetwork.Registry},
      {Finch, name: ContentNetwork.Finch},
      {Oban, Application.fetch_env!(:content_network, Oban)},
      ContentNetwork.Orchestrator,
      ContentNetworkWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ContentNetwork.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ContentNetworkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
