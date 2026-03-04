defmodule ContentNetwork.Repo do
  use Ecto.Repo,
    otp_app: :content_network,
    adapter: Ecto.Adapters.Postgres
end
