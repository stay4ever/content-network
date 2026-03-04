import Config

config :content_network, ContentNetwork.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "content_network_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :content_network, ContentNetworkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_please_change",
  watchers: []

config :content_network, dev_routes: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :content_network, ContentNetwork.ClaudeClient,
  api_key: System.get_env("CLAUDE_API_KEY"),
  model: "claude-sonnet-4-20250514",
  max_tokens: 8192

config :ex_aws,
  access_key_id: [{:system, "R2_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "R2_SECRET_ACCESS_KEY"}, :instance_role],
  region: "auto"

config :ex_aws, :s3,
  scheme: "https://",
  host: {:system, "R2_ENDPOINT"},
  region: "auto"
