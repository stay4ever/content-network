import Config

config :content_network, ContentNetwork.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "content_network_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :content_network, ContentNetworkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only_changeme",
  server: false

config :content_network, Oban, testing: :inline

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
