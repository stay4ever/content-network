defmodule ContentNetworkWeb.DashboardLive do
  use ContentNetworkWeb, :live_view

  alias ContentNetwork.{Sites, Content}

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ContentNetwork.PubSub, "content:updates")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> load_dashboard_data()
      |> assign(:feed, [])
      |> assign(:selected_site, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    site = Sites.get_site!(id)
    articles = Content.list_articles(site_id: site.id, status: :published, limit: 20)
    revenue = Content.revenue_by_type(site.id, 30)

    {:noreply,
     socket
     |> assign(:selected_site, site)
     |> assign(:site_articles, articles)
     |> assign(:site_revenue, revenue)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_site, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info({:article_published, data}, socket) do
    feed_item = %{
      type: :article,
      message: "Published: #{data.article}",
      detail: data.site,
      time: DateTime.utc_now()
    }

    socket =
      socket
      |> update(:feed, fn feed -> Enum.take([feed_item | feed], 20) end)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  def handle_info({:seo_optimized, data}, socket) do
    feed_item = %{
      type: :seo,
      message: "SEO optimized: #{data.article}",
      detail: "#{data.old_score} -> #{data.new_score}",
      time: DateTime.utc_now()
    }

    {:noreply, update(socket, :feed, fn feed -> Enum.take([feed_item | feed], 20) end)}
  end

  def handle_info({:affiliate_report, data}, socket) do
    feed_item = %{
      type: :affiliate,
      message: "Affiliate report: #{data.site}",
      detail: "#{data.summary.total_clicks} clicks, $#{format_cents(data.summary.total_revenue_cents)}",
      time: DateTime.utc_now()
    }

    {:noreply, update(socket, :feed, fn feed -> Enum.take([feed_item | feed], 20) end)}
  end

  def handle_info({:email_sent, data}, socket) do
    feed_item = %{
      type: :email,
      message: "Email sent: #{data.metrics.subject}",
      detail: "#{data.metrics.open_rate}% open rate",
      time: DateTime.utc_now()
    }

    {:noreply, update(socket, :feed, fn feed -> Enum.take([feed_item | feed], 20) end)}
  end

  def handle_info({:site_promoted, data}, socket) do
    feed_item = %{
      type: :promotion,
      message: "#{data.site} promoted to #{data.new_status}",
      detail: "Growth milestone reached",
      time: DateTime.utc_now()
    }

    socket =
      socket
      |> update(:feed, fn feed -> Enum.take([feed_item | feed], 20) end)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  def handle_info({:daily_report, _report}, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info({:weekly_report, _report}, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("trigger_schedule", _params, socket) do
    ContentNetwork.Orchestrator.trigger_schedule()

    feed_item = %{
      type: :system,
      message: "Manual schedule triggered",
      detail: "Content production starting",
      time: DateTime.utc_now()
    }

    {:noreply, update(socket, :feed, fn feed -> Enum.take([feed_item | feed], 20) end)}
  end

  def handle_event("trigger_analytics", _params, socket) do
    ContentNetwork.Orchestrator.trigger_daily_analytics()

    {:noreply, socket}
  end

  defp load_dashboard_data(socket) do
    metrics = Sites.aggregate_metrics()
    sites = Sites.list_sites()
    top_articles = Content.list_top_articles(10)
    recent_articles = Content.list_recent_articles(5)
    revenue_breakdown = Content.revenue_breakdown(30)
    daily_revenue = Content.daily_revenue(14)

    orchestrator_state =
      try do
        ContentNetwork.Orchestrator.get_state()
      rescue
        _ -> %{last_schedule_run: nil, daily_articles_scheduled: 0, active_sites: []}
      end

    target = 1_400_000

    socket
    |> assign(:metrics, metrics)
    |> assign(:sites, sites)
    |> assign(:top_articles, top_articles)
    |> assign(:recent_articles, recent_articles)
    |> assign(:revenue_breakdown, revenue_breakdown)
    |> assign(:daily_revenue, daily_revenue)
    |> assign(:orchestrator, orchestrator_state)
    |> assign(:target_revenue, target)
    |> assign(:progress_pct, Float.round(min(metrics.total_monthly_revenue_cents / max(target, 1) * 100, 100), 1))
  end

  defp format_cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remaining = rem(cents, 100)

    if dollars >= 1000 do
      "#{Float.round(dollars / 1000, 1)}K"
    else
      "#{dollars}.#{String.pad_leading("#{remaining}", 2, "0")}"
    end
  end

  defp format_cents(_), do: "0.00"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"

  defp status_badge_class(status) do
    case status do
      :setup -> "badge badge-setup"
      :growing -> "badge badge-growing"
      :monetized -> "badge badge-monetized"
      :scaling -> "badge badge-scaling"
      :mature -> "badge badge-mature"
      _ -> "badge badge-setup"
    end
  end

  defp feed_dot_color(:article), do: "background: var(--green);"
  defp feed_dot_color(:seo), do: "background: var(--blue);"
  defp feed_dot_color(:affiliate), do: "background: var(--amber);"
  defp feed_dot_color(:email), do: "background: var(--purple);"
  defp feed_dot_color(:promotion), do: "background: var(--green); box-shadow: 0 0 8px var(--green);"
  defp feed_dot_color(:system), do: "background: var(--text-muted);"
  defp feed_dot_color(_), do: "background: var(--text-muted);"

  defp time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp max_revenue(breakdown) do
    breakdown
    |> Map.values()
    |> Enum.max(fn -> 1 end)
  end

  defp revenue_bar_pct(amount, max_val) when max_val > 0, do: Float.round(amount / max_val * 100, 1)
  defp revenue_bar_pct(_, _), do: 0

  defp revenue_type_color(:affiliate), do: "background: linear-gradient(90deg, var(--green-dim), var(--green));"
  defp revenue_type_color(:display_ad), do: "background: linear-gradient(90deg, var(--amber-dim), var(--amber));"
  defp revenue_type_color(:sponsored), do: "background: linear-gradient(90deg, #6644cc, var(--purple));"
  defp revenue_type_color(:email_product), do: "background: linear-gradient(90deg, #2266cc, var(--blue));"
  defp revenue_type_color(_), do: "background: var(--text-muted);"

  defp revenue_type_label(:affiliate), do: "Affiliate"
  defp revenue_type_label(:display_ad), do: "Display Ads"
  defp revenue_type_label(:sponsored), do: "Sponsored"
  defp revenue_type_label(:email_product), do: "Email"
  defp revenue_type_label(type), do: type |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
