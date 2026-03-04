defmodule ContentNetwork.Workers.AnalyticsWorker do
  @moduledoc """
  Aggregates daily metrics across all sites in the content network.

  Tracks pageviews, revenue by source, top articles, and growth trends.
  Generates daily/weekly reports stored to R2.
  Identifies opportunities such as articles ready for affiliate optimization
  and sites ready for Mediavine application.
  """
  use Oban.Worker,
    queue: :analytics,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args]]

  require Logger

  alias ContentNetwork.{Sites, Content, Storage}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "daily_report"}}) do
    Logger.info("[AnalyticsWorker] Generating daily report")

    sites = Sites.list_sites()
    metrics = Sites.aggregate_metrics()
    revenue_breakdown = Content.revenue_breakdown(1)
    top_articles = Content.list_top_articles(10)
    recent_articles = Content.list_recent_articles(10)

    report = %{
      type: "daily",
      date: Date.utc_today() |> Date.to_iso8601(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      network_summary: %{
        total_sites: metrics.total_sites,
        total_articles: metrics.total_articles,
        monthly_revenue_cents: metrics.total_monthly_revenue_cents,
        monthly_pageviews: metrics.total_monthly_pageviews,
        email_subscribers: metrics.total_email_subscribers,
        target_revenue_cents: 1_400_000,
        revenue_progress_pct: Float.round(metrics.total_monthly_revenue_cents / 1_400_000 * 100, 1)
      },
      revenue: %{
        today: revenue_breakdown,
        breakdown: %{
          affiliate: Map.get(revenue_breakdown, :affiliate, 0),
          display_ad: Map.get(revenue_breakdown, :display_ad, 0),
          sponsored: Map.get(revenue_breakdown, :sponsored, 0),
          email_product: Map.get(revenue_breakdown, :email_product, 0)
        }
      },
      sites: Enum.map(sites, &site_summary/1),
      top_articles: Enum.map(top_articles, &article_summary/1),
      recent_articles: Enum.map(recent_articles, &article_summary/1),
      opportunities: identify_opportunities(sites, top_articles),
      health_checks: run_health_checks(sites)
    }

    store_report("daily", report)
    broadcast_daily_report(report)

    Logger.info("[AnalyticsWorker] Daily report complete — #{metrics.total_sites} sites, $#{Float.round(metrics.total_monthly_revenue_cents / 100, 2)} revenue")
    {:ok, :daily_report_generated}
  end

  def perform(%Oban.Job{args: %{"action" => "weekly_report"}}) do
    Logger.info("[AnalyticsWorker] Generating weekly report")

    sites = Sites.list_sites()
    metrics = Sites.aggregate_metrics()
    revenue_7d = Content.total_revenue(7)
    revenue_30d = Content.total_revenue(30)
    daily_revenue = Content.daily_revenue(7)

    weekly_growth =
      if revenue_30d > 0 do
        Float.round((revenue_7d / (revenue_30d / 4) - 1) * 100, 1)
      else
        0.0
      end

    report = %{
      type: "weekly",
      week_ending: Date.utc_today() |> Date.to_iso8601(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      network_summary: %{
        total_sites: metrics.total_sites,
        total_articles: metrics.total_articles,
        weekly_revenue_cents: revenue_7d,
        monthly_revenue_cents: metrics.total_monthly_revenue_cents,
        weekly_growth_pct: weekly_growth,
        monthly_pageviews: metrics.total_monthly_pageviews,
        email_subscribers: metrics.total_email_subscribers
      },
      daily_revenue_trend: Enum.map(daily_revenue, fn {date, cents} ->
        %{date: Date.to_iso8601(date), amount_cents: cents}
      end),
      sites: Enum.map(sites, &detailed_site_summary/1),
      content_production: %{
        articles_this_week: Content.list_articles(limit: 100)
          |> Enum.count(fn a ->
            a.inserted_at &&
            DateTime.compare(a.inserted_at, DateTime.add(DateTime.utc_now(), -7 * 86400, :second)) == :gt
          end),
        avg_seo_score: calculate_avg_seo_score(sites),
        top_performing_keywords: get_top_keywords()
      },
      growth_plan: generate_growth_plan(sites, metrics)
    }

    store_report("weekly", report)
    broadcast_weekly_report(report)

    Logger.info("[AnalyticsWorker] Weekly report complete — growth: #{weekly_growth}%")
    {:ok, :weekly_report_generated}
  end

  def perform(%Oban.Job{args: %{"action" => "simulate_traffic", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    articles = Content.list_articles(site_id: site_id, status: :published, limit: 200)

    total_views = simulate_site_traffic(site, articles)
    Sites.update_pageviews(site, total_views)

    # Generate display ad revenue if Mediavine approved
    if site.mediavine_approved and total_views > 0 do
      rpm = 15 + :rand.uniform(25)
      daily_ad_revenue = round(total_views / 30 * rpm / 1000 * 100)

      if daily_ad_revenue > 0 do
        Content.create_revenue_event(%{
          site_id: site_id,
          type: :display_ad,
          amount_cents: daily_ad_revenue,
          source: "mediavine",
          metadata: %{"pageviews" => total_views, "rpm" => rpm}
        })
      end
    end

    Logger.info("[AnalyticsWorker] Traffic simulation for #{site.domain}: #{total_views} monthly PV")
    {:ok, total_views}
  end

  defp site_summary(site) do
    %{
      id: site.id,
      name: site.name,
      domain: site.domain,
      niche: site.niche,
      status: site.status,
      articles: site.article_count,
      pageviews: site.monthly_pageviews,
      revenue_cents: site.monthly_revenue_cents,
      subscribers: site.email_subscribers,
      da: site.domain_authority,
      mediavine: site.mediavine_approved
    }
  end

  defp detailed_site_summary(site) do
    revenue_by_type = Content.revenue_by_type(site.id, 7)

    Map.merge(site_summary(site), %{
      weekly_revenue: revenue_by_type,
      growth_stage: Sites.Site.revenue_tier(site),
      mediavine_eligible: Sites.Site.mediavine_eligible?(site),
      affiliate_programs: site.affiliate_programs
    })
  end

  defp article_summary(article) do
    %{
      id: article.id,
      title: article.title,
      slug: article.slug,
      site: if(Ecto.assoc_loaded?(article.site), do: article.site.domain, else: nil),
      keyword: article.target_keyword,
      word_count: article.word_count,
      pageviews: article.pageviews,
      affiliate_clicks: article.affiliate_clicks,
      revenue_cents: article.affiliate_revenue_cents,
      seo_score: article.seo_score,
      search_position: article.search_position,
      published_at: article.published_at
    }
  end

  defp identify_opportunities(sites, _top_articles) do
    opportunities = []

    # Sites ready for Mediavine
    mediavine_ready =
      sites
      |> Enum.filter(fn s -> not s.mediavine_approved and Sites.Site.mediavine_eligible?(s) end)
      |> Enum.map(fn s -> %{type: "mediavine_ready", site: s.domain, pageviews: s.monthly_pageviews} end)

    # Sites needing more content
    content_gaps =
      sites
      |> Enum.filter(fn s -> s.article_count < 50 and s.status in [:growing, :monetized] end)
      |> Enum.map(fn s ->
        %{type: "needs_content", site: s.domain, articles: s.article_count, target: 50}
      end)

    # Sites with low affiliate optimization
    affiliate_gaps =
      sites
      |> Enum.filter(fn s -> length(s.affiliate_programs) < 2 and s.article_count > 10 end)
      |> Enum.map(fn s ->
        %{type: "needs_affiliates", site: s.domain, current_programs: length(s.affiliate_programs)}
      end)

    # Sites with low email subscribers
    email_gaps =
      sites
      |> Enum.filter(fn s -> s.email_subscribers < 100 and s.monthly_pageviews > 1000 end)
      |> Enum.map(fn s ->
        %{type: "needs_email_growth", site: s.domain, subscribers: s.email_subscribers}
      end)

    opportunities ++ mediavine_ready ++ content_gaps ++ affiliate_gaps ++ email_gaps
  end

  defp run_health_checks(sites) do
    Enum.map(sites, fn site ->
      issues = []

      issues = if site.article_count == 0, do: ["no_articles" | issues], else: issues
      issues = if site.monthly_pageviews == 0 and site.article_count > 10, do: ["zero_traffic" | issues], else: issues
      issues = if site.monthly_revenue_cents == 0 and site.monthly_pageviews > 5000, do: ["no_revenue" | issues], else: issues
      issues = if site.status == :setup and site.article_count > 20, do: ["stuck_in_setup" | issues], else: issues

      %{
        site: site.domain,
        status: if(issues == [], do: :healthy, else: :attention_needed),
        issues: issues
      }
    end)
  end

  defp simulate_site_traffic(site, articles) do
    base_traffic =
      case site.status do
        :mature -> 5000
        :scaling -> 2000
        :monetized -> 800
        :growing -> 200
        :setup -> 50
      end

    article_traffic =
      Enum.reduce(articles, 0, fn article, acc ->
        article_age_days =
          if article.published_at do
            DateTime.diff(DateTime.utc_now(), article.published_at, :day)
          else
            30
          end

        age_multiplier =
          cond do
            article_age_days > 180 -> 1.5
            article_age_days > 90 -> 1.2
            article_age_days > 30 -> 0.8
            true -> 0.3
          end

        seo_multiplier = max((article.seo_score || 50) / 100, 0.2)
        article_views = round(base_traffic * 0.1 * age_multiplier * seo_multiplier * (0.5 + :rand.uniform()))

        Content.update_article(article, %{pageviews: article.pageviews + article_views})
        acc + article_views
      end)

    base_traffic + article_traffic
  end

  defp calculate_avg_seo_score(sites) do
    all_articles =
      Enum.flat_map(sites, fn site ->
        Content.list_articles(site_id: site.id, status: :published, limit: 100)
      end)

    if all_articles == [] do
      0
    else
      scores = Enum.map(all_articles, fn a -> a.seo_score || 0 end)
      div(Enum.sum(scores), length(scores))
    end
  end

  defp get_top_keywords do
    Content.list_top_articles(5)
    |> Enum.map(fn a -> %{keyword: a.target_keyword, revenue_cents: a.affiliate_revenue_cents} end)
  end

  defp generate_growth_plan(sites, metrics) do
    target = 1_400_000
    current = metrics.total_monthly_revenue_cents
    gap = target - current

    %{
      current_monthly_cents: current,
      target_monthly_cents: target,
      gap_cents: max(gap, 0),
      progress_pct: Float.round(min(current / target * 100, 100), 1),
      recommendations:
        cond do
          current >= target ->
            ["Target reached! Focus on sustainability and growth."]

          current >= target * 0.75 ->
            [
              "Close to target — optimize top-performing articles",
              "Apply for Mediavine on eligible sites",
              "Scale email marketing for product promotions"
            ]

          current >= target * 0.50 ->
            [
              "Accelerate content production to 5+ articles/day/site",
              "Focus on buyer-intent keywords for higher conversion",
              "Join 2+ additional affiliate programs per site"
            ]

          true ->
            [
              "Priority: publish 3-5 articles daily per site",
              "Focus on long-tail, low-competition keywords",
              "Build email lists with lead magnets",
              "Consider launching #{max(5 - length(sites), 1)} additional niche sites"
            ]
        end
    }
  end

  defp store_report(type, report) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = "reports/#{type}-#{date}.json"

    case Storage.put_object(key, Jason.encode!(report), content_type: "application/json") do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[AnalyticsWorker] Failed to store #{type} report: #{inspect(reason)}")
    end
  end

  defp broadcast_daily_report(report) do
    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:daily_report, report}
    )
  end

  defp broadcast_weekly_report(report) do
    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:weekly_report, report}
    )
  end
end
