import Config

config :content_network, ContentNetworkWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :content_network, ContentNetwork.Repo,
  pool_size: 20

config :logger, level: :info
