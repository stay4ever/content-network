defmodule ContentNetworkWeb.ApiController do
  use ContentNetworkWeb, :controller

  alias ContentNetwork.{Sites, Content}

  def sites(conn, _params) do
    sites = Sites.list_sites()

    json(conn, %{
      sites:
        Enum.map(sites, fn site ->
          %{
            id: site.id,
            name: site.name,
            domain: site.domain,
            niche: site.niche,
            description: site.description,
            status: site.status,
            monthly_pageviews: site.monthly_pageviews,
            monthly_revenue_cents: site.monthly_revenue_cents,
            total_revenue_cents: site.total_revenue_cents,
            article_count: site.article_count,
            email_subscribers: site.email_subscribers,
            domain_authority: site.domain_authority,
            affiliate_programs: site.affiliate_programs,
            mediavine_approved: site.mediavine_approved,
            inserted_at: site.inserted_at
          }
        end),
      total: length(sites)
    })
  end

  def metrics(conn, _params) do
    metrics = Sites.aggregate_metrics()
    revenue_breakdown = Content.revenue_breakdown(30)
    daily_revenue = Content.daily_revenue(30)

    json(conn, %{
      network: %{
        total_sites: metrics.total_sites,
        total_articles: metrics.total_articles,
        monthly_revenue_cents: metrics.total_monthly_revenue_cents,
        monthly_pageviews: metrics.total_monthly_pageviews,
        email_subscribers: metrics.total_email_subscribers,
        mediavine_sites: metrics.mediavine_sites,
        avg_domain_authority: metrics.avg_domain_authority,
        target_revenue_cents: 1_400_000,
        progress_pct:
          if metrics.total_monthly_revenue_cents > 0 do
            Float.round(metrics.total_monthly_revenue_cents / 1_400_000 * 100, 1)
          else
            0.0
          end
      },
      revenue_breakdown:
        Map.new(revenue_breakdown, fn {type, cents} ->
          {Atom.to_string(type), cents}
        end),
      daily_revenue:
        Enum.map(daily_revenue, fn {date, cents} ->
          %{date: Date.to_iso8601(date), amount_cents: cents}
        end),
      sites_by_status:
        Map.new(metrics.sites_by_status, fn {status, count} ->
          {Atom.to_string(status), count}
        end)
    })
  end

  def articles(conn, params) do
    limit = parse_int(params["limit"], 20)
    site_id = params["site_id"]

    articles =
      if site_id do
        Content.list_articles(site_id: String.to_integer(site_id), status: :published, limit: limit)
      else
        Content.list_recent_articles(limit)
      end

    top_articles = Content.list_top_articles(10)

    json(conn, %{
      articles:
        Enum.map(articles, fn article ->
          %{
            id: article.id,
            title: article.title,
            slug: article.slug,
            site: if(Ecto.assoc_loaded?(article.site), do: article.site.domain, else: nil),
            target_keyword: article.target_keyword,
            word_count: article.word_count,
            status: article.status,
            pageviews: article.pageviews,
            affiliate_clicks: article.affiliate_clicks,
            affiliate_revenue_cents: article.affiliate_revenue_cents,
            seo_score: article.seo_score,
            search_position: article.search_position,
            published_at: article.published_at
          }
        end),
      top_articles:
        Enum.map(top_articles, fn article ->
          %{
            id: article.id,
            title: article.title,
            site: if(Ecto.assoc_loaded?(article.site), do: article.site.domain, else: nil),
            revenue_cents: article.affiliate_revenue_cents,
            pageviews: article.pageviews,
            seo_score: article.seo_score
          }
        end),
      total: Content.total_article_count()
    })
  end

  def revenue(conn, params) do
    days = parse_int(params["days"], 30)

    json(conn, %{
      total_cents: Content.total_revenue(days),
      breakdown: Content.revenue_breakdown(days),
      daily: Content.daily_revenue(days)
        |> Enum.map(fn {date, cents} -> %{date: Date.to_iso8601(date), amount_cents: cents} end)
    })
  end

  def health(conn, _params) do
    db_status =
      try do
        ContentNetwork.Repo.query!("SELECT 1")
        :ok
      rescue
        _ -> :error
      end

    orchestrator_state =
      try do
        ContentNetwork.Orchestrator.get_state()
      rescue
        _ -> nil
      end

    json(conn, %{
      status: if(db_status == :ok, do: "healthy", else: "degraded"),
      database: db_status,
      orchestrator: %{
        running: orchestrator_state != nil,
        last_schedule: orchestrator_state && orchestrator_state.last_schedule_run,
        articles_scheduled_today: orchestrator_state && orchestrator_state.daily_articles_scheduled,
        active_sites: orchestrator_state && orchestrator_state.active_sites
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
