defmodule ContentNetworkWeb.Router do
  use ContentNetworkWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContentNetworkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ContentNetworkWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/sites/:id", DashboardLive, :site_detail
  end

  scope "/api", ContentNetworkWeb do
    pipe_through :api

    get "/sites", ApiController, :sites
    get "/metrics", ApiController, :metrics
    get "/articles", ApiController, :articles
    get "/revenue", ApiController, :revenue
    get "/health", ApiController, :health
  end

  if Application.compile_env(:content_network, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
