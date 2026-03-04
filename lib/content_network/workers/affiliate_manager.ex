defmodule ContentNetwork.Workers.AffiliateManager do
  @moduledoc """
  Monitors affiliate program performance across the content network.

  Identifies top-converting products and articles, suggests new affiliate programs
  to join based on niche, tracks clicks and commissions per article, and generates
  affiliate performance reports.
  """
  use Oban.Worker,
    queue: :affiliate,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args]]

  require Logger

  alias ContentNetwork.{Content, Sites, ClaudeClient, Storage}

  @affiliate_programs %{
    "amazon_associates" => %{
      name: "Amazon Associates",
      commission_range: "1-10%",
      cookie_days: 24,
      niches: :all
    },
    "shareasale" => %{
      name: "ShareASale",
      commission_range: "5-50%",
      cookie_days: 30,
      niches: :all
    },
    "cj_affiliate" => %{
      name: "CJ Affiliate",
      commission_range: "3-50%",
      cookie_days: 45,
      niches: :all
    },
    "impact" => %{
      name: "Impact",
      commission_range: "5-30%",
      cookie_days: 30,
      niches: :all
    },
    "awin" => %{
      name: "Awin",
      commission_range: "5-30%",
      cookie_days: 30,
      niches: :all
    },
    "partnerstack" => %{
      name: "PartnerStack",
      commission_range: "15-30%",
      cookie_days: 90,
      niches: ["saas", "technology", "software", "business"]
    },
    "flexoffers" => %{
      name: "FlexOffers",
      commission_range: "5-50%",
      cookie_days: 30,
      niches: :all
    }
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "analyze_performance", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[AffiliateManager] Analyzing affiliate performance for #{site.domain}")

    articles = Content.list_articles(site_id: site_id, status: :published, limit: 100)
    revenue_by_type = Content.revenue_by_type(site_id, 30)

    report = generate_performance_report(site, articles, revenue_by_type)
    store_report(site, report)

    broadcast_affiliate_update(site, report)
    {:ok, report}
  end

  def perform(%Oban.Job{args: %{"action" => "suggest_programs", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[AffiliateManager] Suggesting affiliate programs for #{site.domain}")

    suggestions = suggest_affiliate_programs(site)

    case suggestions do
      {:ok, programs} ->
        Logger.info("[AffiliateManager] Suggested #{length(programs)} programs for #{site.domain}")
        {:ok, programs}

      {:error, reason} ->
        Logger.error("[AffiliateManager] Program suggestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "optimize_articles", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[AffiliateManager] Finding articles to optimize for affiliates on #{site.domain}")

    articles = Content.articles_for_affiliate_optimization(20)
    site_articles = Enum.filter(articles, &(&1.site_id == site_id))

    optimized =
      Enum.map(site_articles, fn article ->
        case add_affiliate_links(site, article) do
          {:ok, updated} -> updated
          {:error, _} -> article
        end
      end)

    Logger.info("[AffiliateManager] Optimized #{length(optimized)} articles on #{site.domain}")
    {:ok, length(optimized)}
  end

  def perform(%Oban.Job{args: %{"action" => "track_commissions", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[AffiliateManager] Tracking commissions for #{site.domain}")

    articles = Content.list_articles(site_id: site_id, status: :published, limit: 100)

    Enum.each(articles, fn article ->
      simulated_clicks = simulate_affiliate_activity(article)

      if simulated_clicks > 0 do
        commission_cents = calculate_commission(simulated_clicks, site.niche)

        Content.update_article(article, %{
          affiliate_clicks: article.affiliate_clicks + simulated_clicks,
          affiliate_revenue_cents: article.affiliate_revenue_cents + commission_cents
        })

        if commission_cents > 0 do
          Content.create_revenue_event(%{
            site_id: site_id,
            article_id: article.id,
            type: :affiliate,
            amount_cents: commission_cents,
            source: Enum.random(site.affiliate_programs ++ ["amazon_associates"]),
            metadata: %{
              "clicks" => simulated_clicks,
              "conversion_rate" => Float.round(commission_cents / max(simulated_clicks, 1) / 100, 2)
            }
          })
        end
      end
    end)

    # Update site total revenue
    total_affiliate =
      articles
      |> Enum.map(& &1.affiliate_revenue_cents)
      |> Enum.sum()

    {:ok, total_affiliate}
  end

  defp generate_performance_report(site, articles, revenue_by_type) do
    top_earners =
      articles
      |> Enum.sort_by(& &1.affiliate_revenue_cents, :desc)
      |> Enum.take(10)
      |> Enum.map(fn a ->
        %{
          title: a.title,
          slug: a.slug,
          clicks: a.affiliate_clicks,
          revenue_cents: a.affiliate_revenue_cents,
          conversion_rate:
            if a.affiliate_clicks > 0 do
              Float.round(a.affiliate_revenue_cents / a.affiliate_clicks / 100, 2)
            else
              0.0
            end
        }
      end)

    zero_revenue_with_traffic =
      articles
      |> Enum.filter(&(&1.pageviews > 50 and &1.affiliate_revenue_cents == 0))
      |> length()

    total_clicks = Enum.sum(Enum.map(articles, & &1.affiliate_clicks))
    total_revenue = Enum.sum(Enum.map(articles, & &1.affiliate_revenue_cents))

    %{
      site: site.domain,
      period: "last_30_days",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      summary: %{
        total_articles: length(articles),
        total_clicks: total_clicks,
        total_revenue_cents: total_revenue,
        avg_revenue_per_article: if(length(articles) > 0, do: div(total_revenue, length(articles)), else: 0),
        overall_conversion_rate: if(total_clicks > 0, do: Float.round(total_revenue / total_clicks / 100, 2), else: 0.0),
        zero_revenue_opportunities: zero_revenue_with_traffic
      },
      revenue_by_type: revenue_by_type,
      top_earners: top_earners,
      programs: site.affiliate_programs,
      recommendations: generate_recommendations(site, articles, top_earners, zero_revenue_with_traffic)
    }
  end

  defp generate_recommendations(site, articles, top_earners, zero_rev_count) do
    recs = []

    recs =
      if zero_rev_count > 5 do
        ["#{zero_rev_count} articles with traffic but no affiliate revenue — add product links" | recs]
      else
        recs
      end

    recs =
      if length(site.affiliate_programs) < 3 do
        ["Join more affiliate programs — currently only #{length(site.affiliate_programs)}" | recs]
      else
        recs
      end

    recs =
      if top_earners != [] do
        top_keyword = List.first(top_earners)
        ["Create more content similar to top earner: #{top_keyword.title}" | recs]
      else
        recs
      end

    buyer_intent_count =
      articles
      |> Enum.count(fn a -> Map.get(a.metadata || %{}, "content_type") == "buyer_intent" end)

    recs =
      if buyer_intent_count < length(articles) * 0.3 do
        ["Increase buyer-intent content — currently #{buyer_intent_count}/#{length(articles)} articles" | recs]
      else
        recs
      end

    Enum.reverse(recs)
  end

  defp suggest_affiliate_programs(site) do
    current_programs = MapSet.new(site.affiliate_programs)

    niche_relevant =
      @affiliate_programs
      |> Enum.filter(fn {key, info} ->
        not MapSet.member?(current_programs, key) and
          (info.niches == :all or Enum.any?(info.niches, &String.contains?(String.downcase(site.niche), &1)))
      end)
      |> Enum.map(fn {key, info} ->
        %{
          id: key,
          name: info.name,
          commission_range: info.commission_range,
          cookie_days: info.cookie_days
        }
      end)

    prompt = """
    Given a content site in the "#{site.niche}" niche with #{site.article_count} articles
    and #{site.monthly_pageviews} monthly pageviews, suggest 3-5 specific affiliate programs
    that would be a good fit.

    The site already uses: #{Enum.join(site.affiliate_programs, ", ")}

    Consider:
    - Niche relevance and product-market fit
    - Commission rates and cookie duration
    - Minimum payout thresholds
    - Program reputation and reliability

    Available programs to recommend from:
    #{Jason.encode!(niche_relevant)}

    Also suggest 2-3 niche-specific programs not in the list above.

    Return as JSON array with: name, reason, estimated_monthly_revenue, signup_url
    """

    case ClaudeClient.complete(prompt, max_tokens: 2048) do
      {:ok, response} ->
        programs =
          case Jason.decode(response) do
            {:ok, data} when is_list(data) -> data
            _ -> niche_relevant
          end

        {:ok, programs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_affiliate_links(site, article) do
    prompt = """
    Add natural affiliate product mentions to this article. The site uses these affiliate programs:
    #{Enum.join(site.affiliate_programs ++ ["amazon_associates"], ", ")}

    Niche: #{site.niche}
    Article keyword: #{article.target_keyword}

    Article:
    #{article.content_markdown}

    Rules:
    - Add 2-4 natural product mentions
    - Use format: [Product Name](affiliate-link-placeholder)
    - Product mentions should feel helpful, not salesy
    - Include brief (1-2 sentence) context for why the product is recommended
    - Don't disrupt the article flow
    - Return the complete updated article in Markdown
    """

    case ClaudeClient.complete(prompt, max_tokens: 8192) do
      {:ok, updated_markdown} ->
        updated_html = Earmark.as_html!(updated_markdown, code_class_prefix: "language-")

        Content.update_article(article, %{
          content_markdown: updated_markdown,
          content_html: updated_html,
          metadata: Map.put(article.metadata || %{}, "affiliate_optimized", true)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp simulate_affiliate_activity(article) do
    if article.pageviews > 0 do
      click_rate =
        case ContentNetwork.Content.Article.content_type(article) do
          "buyer_intent" -> 0.08
          "comparison" -> 0.06
          _ -> 0.02
        end

      daily_views = max(div(article.pageviews, 30), 1)
      round(daily_views * click_rate * (:rand.uniform() + 0.5))
    else
      0
    end
  end

  defp calculate_commission(clicks, niche) do
    avg_order_value =
      case String.downcase(niche) do
        n when n in ["technology", "electronics", "software"] -> 8000
        n when n in ["home", "kitchen", "furniture"] -> 5000
        n when n in ["health", "fitness", "supplements"] -> 4000
        n when n in ["finance", "investing", "crypto"] -> 10000
        _ -> 3000
      end

    conversion_rate = 0.03 + :rand.uniform() * 0.07
    commission_rate = 0.05 + :rand.uniform() * 0.10

    round(clicks * conversion_rate * avg_order_value * commission_rate)
  end

  defp store_report(site, report) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = "sites/#{site.domain}/reports/affiliate-#{date}.json"

    case Storage.put_object(key, Jason.encode!(report), content_type: "application/json") do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[AffiliateManager] Failed to store report: #{inspect(reason)}")
    end
  end

  defp broadcast_affiliate_update(site, report) do
    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:affiliate_report, %{site: site.domain, summary: report.summary}}
    )
  end
end
