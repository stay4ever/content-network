import Config

if System.get_env("PHX_SERVER") do
  config :content_network, ContentNetworkWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :content_network, ContentNetwork.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "content-network.fly.dev"
  port = String.to_integer(System.get_env("PORT") || "4002")

  config :content_network, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :content_network, ContentNetworkWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :content_network, ContentNetwork.ClaudeClient,
    api_key: System.get_env("CLAUDE_API_KEY"),
    model: System.get_env("CLAUDE_MODEL") || "claude-sonnet-4-20250514",
    max_tokens: String.to_integer(System.get_env("CLAUDE_MAX_TOKENS") || "8192")

  config :ex_aws,
    access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
    region: "auto"

  config :ex_aws, :s3,
    scheme: "https://",
    host: System.get_env("R2_ENDPOINT"),
    region: "auto"

  config :content_network, ContentNetwork.Storage,
    bucket: System.get_env("R2_BUCKET") || "content-network-assets"

  config :content_network, Oban,
    repo: ContentNetwork.Repo,
    queues: [
      content: String.to_integer(System.get_env("OBAN_CONTENT_LIMIT") || "2"),
      seo: String.to_integer(System.get_env("OBAN_SEO_LIMIT") || "1"),
      affiliate: String.to_integer(System.get_env("OBAN_AFFILIATE_LIMIT") || "1"),
      email: String.to_integer(System.get_env("OBAN_EMAIL_LIMIT") || "1"),
      analytics: String.to_integer(System.get_env("OBAN_ANALYTICS_LIMIT") || "1")
    ]
end
