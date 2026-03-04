import Config

config :content_network,
  ecto_repos: [ContentNetwork.Repo],
  generators: [timestamp_type: :utc_datetime]

config :content_network, ContentNetworkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ContentNetworkWeb.ErrorHTML, json: ContentNetworkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ContentNetwork.PubSub,
  live_view: [signing_salt: "c0nt3ntN3tw0rk"]

config :content_network, Oban,
  repo: ContentNetwork.Repo,
  queues: [
    content: 2,
    seo: 1,
    affiliate: 1,
    email: 1,
    analytics: 1
  ]

config :content_network, ContentNetwork.ClaudeClient,
  model: "claude-sonnet-4-20250514",
  max_tokens: 8192

config :content_network, ContentNetwork.Storage,
  bucket: "content-network-assets"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
