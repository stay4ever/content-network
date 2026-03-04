defmodule ContentNetwork.Orchestrator do
  @moduledoc """
  Manages the content calendar across all sites in the network.

  Schedules 3-5 articles per site per day, prioritizes sites based on growth stage,
  balances content types (informational 60%, buyer intent 30%, comparison 10%),
  monitors site health, and triggers new site creation when existing sites plateau.
  """
  use GenServer
  require Logger

  alias ContentNetwork.Sites
  alias ContentNetwork.Workers.{ContentWriter, SeoOptimizer, AffiliateManager, EmailManager, AnalyticsWorker}

  @schedule_interval :timer.minutes(30)
  @daily_articles_per_site 3..5
  @content_mix %{
    informational: 0.60,
    buyer_intent: 0.30,
    comparison: 0.10
  }

  defstruct [
    :last_schedule_run,
    :daily_articles_scheduled,
    :active_sites,
    schedule_running: false
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def trigger_schedule do
    GenServer.cast(__MODULE__, :run_schedule)
  end

  def trigger_daily_analytics do
    GenServer.cast(__MODULE__, :daily_analytics)
  end

  @impl true
  def init(_) do
    state = %__MODULE__{
      last_schedule_run: nil,
      daily_articles_scheduled: 0,
      active_sites: []
    }

    schedule_next_run()
    schedule_daily_tasks()

    Logger.info("[Orchestrator] Started — scheduling content production")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:run_schedule, %{schedule_running: true} = state) do
    Logger.info("[Orchestrator] Schedule already running, skipping")
    {:noreply, state}
  end

  def handle_cast(:run_schedule, state) do
    state = %{state | schedule_running: true}
    send(self(), :execute_schedule)
    {:noreply, state}
  end

  def handle_cast(:daily_analytics, state) do
    run_daily_analytics()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_run, state) do
    send(self(), :execute_schedule)
    schedule_next_run()
    {:noreply, %{state | schedule_running: true}}
  end

  def handle_info(:daily_tasks, state) do
    run_daily_tasks()
    schedule_daily_tasks()
    {:noreply, state}
  end

  def handle_info(:execute_schedule, state) do
    sites = Sites.list_active_sites()

    if sites == [] do
      Logger.info("[Orchestrator] No active sites — waiting for site creation")
      {:noreply, %{state | schedule_running: false, active_sites: []}}
    else
      total_scheduled = schedule_content_for_sites(sites)

      Logger.info("[Orchestrator] Scheduled #{total_scheduled} articles across #{length(sites)} sites")

      new_state = %{state |
        schedule_running: false,
        last_schedule_run: DateTime.utc_now(),
        daily_articles_scheduled: state.daily_articles_scheduled + total_scheduled,
        active_sites: Enum.map(sites, & &1.domain)
      }

      {:noreply, new_state}
    end
  end

  defp schedule_content_for_sites(sites) do
    prioritized = prioritize_sites(sites)

    Enum.reduce(prioritized, 0, fn {site, priority}, acc ->
      articles_to_schedule = calculate_article_count(site, priority)
      keywords = generate_keywords_for_site(site, articles_to_schedule)

      Enum.each(keywords, fn {keyword, content_type, secondary} ->
        Oban.insert!(ContentWriter.new(%{
          "site_id" => site.id,
          "target_keyword" => keyword,
          "content_type" => content_type,
          "secondary_keywords" => secondary
        }))
      end)

      acc + length(keywords)
    end)
  end

  defp prioritize_sites(sites) do
    sites
    |> Enum.map(fn site ->
      priority =
        case site.status do
          :growing -> 10
          :monetized -> 8
          :setup -> 6
          :scaling -> 5
          :mature -> 3
        end

      # Boost sites with low article count
      priority = if site.article_count < 30, do: priority + 5, else: priority

      # Boost sites with high revenue potential
      priority = if site.monthly_pageviews > 10_000 and site.monthly_revenue_cents < 50_000 do
        priority + 3
      else
        priority
      end

      {site, priority}
    end)
    |> Enum.sort_by(fn {_, p} -> p end, :desc)
  end

  defp calculate_article_count(site, priority) do
    base = Enum.random(@daily_articles_per_site)

    cond do
      priority >= 12 -> base + 2
      priority >= 8 -> base + 1
      priority >= 5 -> base
      true -> max(base - 1, 1)
    end
  end

  defp generate_keywords_for_site(site, count) do
    content_types = distribute_content_types(count)

    content_types
    |> Enum.map(fn content_type ->
      keyword = generate_keyword(site.niche, content_type)
      secondary = generate_secondary_keywords(site.niche, keyword, content_type)
      {keyword, content_type, secondary}
    end)
  end

  defp distribute_content_types(count) do
    informational_count = round(count * @content_mix.informational)
    buyer_count = round(count * @content_mix.buyer_intent)
    comparison_count = max(count - informational_count - buyer_count, 0)

    List.duplicate("informational", informational_count) ++
      List.duplicate("buyer_intent", buyer_count) ++
      List.duplicate("comparison", comparison_count)
  end

  defp generate_keyword(niche, content_type) do
    niche_lower = String.downcase(niche)

    prefixes =
      case content_type do
        "informational" ->
          ["how to", "what is", "guide to", "tips for", "understanding", "complete guide",
           "beginner's guide to", "everything about", "why", "when to"]

        "buyer_intent" ->
          ["best", "top", "review", "affordable", "premium", "budget",
           "professional", "recommended", "worth buying", "best value"]

        "comparison" ->
          ["vs", "compared to", "alternative to", "or", "which is better",
           "difference between"]
      end

    topics = niche_keyword_topics(niche_lower)
    prefix = Enum.random(prefixes)
    topic = Enum.random(topics)

    year = Date.utc_today().year

    case content_type do
      "buyer_intent" -> "#{prefix} #{topic} #{year}"
      "comparison" -> "#{Enum.random(topics)} #{prefix} #{topic}"
      _ -> "#{prefix} #{topic}"
    end
  end

  defp generate_secondary_keywords(niche, _primary, _content_type) do
    topics = niche_keyword_topics(String.downcase(niche))
    Enum.take_random(topics, 3)
  end

  defp niche_keyword_topics(niche) do
    base_topics = String.split(niche, ~r/[\s,]+/)

    expansions =
      case niche do
        n when n in ["technology", "tech", "gadgets"] ->
          ["laptop", "smartphone", "headphones", "monitor", "keyboard", "mouse",
           "tablet", "smartwatch", "speaker", "camera", "drone", "router"]

        n when n in ["health", "fitness", "wellness"] ->
          ["protein powder", "yoga mat", "running shoes", "fitness tracker",
           "supplements", "home gym", "resistance bands", "foam roller"]

        n when n in ["home", "kitchen", "cooking"] ->
          ["air fryer", "instant pot", "blender", "knife set", "cookware",
           "coffee maker", "food processor", "cutting board", "spice rack"]

        n when n in ["finance", "investing", "money"] ->
          ["savings account", "credit card", "budgeting app", "investment platform",
           "robo advisor", "stock broker", "crypto exchange", "tax software"]

        n when n in ["outdoor", "camping", "hiking"] ->
          ["backpack", "tent", "sleeping bag", "hiking boots", "water filter",
           "camping stove", "trekking poles", "headlamp", "cooler"]

        _ ->
          ["product", "tool", "service", "solution", "equipment",
           "accessory", "system", "platform", "software", "gear"]
      end

    base_topics ++ expansions
  end

  defp run_daily_tasks do
    Logger.info("[Orchestrator] Running daily maintenance tasks")

    sites = Sites.list_active_sites()

    Enum.each(sites, fn site ->
      # SEO batch audit
      Oban.insert!(SeoOptimizer.new(%{
        "action" => "batch_audit",
        "site_id" => site.id
      }))

      # Affiliate performance tracking
      Oban.insert!(AffiliateManager.new(%{
        "action" => "track_commissions",
        "site_id" => site.id
      }))

      # Email subscriber metrics
      Oban.insert!(EmailManager.new(%{
        "action" => "update_subscriber_metrics",
        "site_id" => site.id
      }))

      # Traffic simulation
      Oban.insert!(AnalyticsWorker.new(%{
        "action" => "simulate_traffic",
        "site_id" => site.id
      }))

      # Weekly newsletter (on Mondays)
      if Date.day_of_week(Date.utc_today()) == 1 do
        Oban.insert!(EmailManager.new(%{
          "action" => "create_newsletter",
          "site_id" => site.id
        }))
      end
    end)

    # Check for sites needing status upgrade
    check_site_promotions(sites)
  end

  defp run_daily_analytics do
    Oban.insert!(AnalyticsWorker.new(%{"action" => "daily_report"}))

    if Date.day_of_week(Date.utc_today()) == 1 do
      Oban.insert!(AnalyticsWorker.new(%{"action" => "weekly_report"}))
    end
  end

  defp check_site_promotions(sites) do
    Enum.each(sites, fn site ->
      new_status =
        cond do
          site.status == :setup and site.article_count >= 10 -> :growing
          site.status == :growing and site.monthly_revenue_cents > 10_000 -> :monetized
          site.status == :monetized and site.monthly_revenue_cents > 200_000 -> :scaling
          site.status == :scaling and site.monthly_revenue_cents > 500_000 -> :mature
          true -> nil
        end

      if new_status do
        Sites.update_site(site, %{status: new_status})
        Logger.info("[Orchestrator] Promoted #{site.domain} to #{new_status}")

        Phoenix.PubSub.broadcast(
          ContentNetwork.PubSub,
          "content:updates",
          {:site_promoted, %{site: site.domain, new_status: new_status}}
        )
      end

      # Auto-approve Mediavine when eligible
      if not site.mediavine_approved and Sites.Site.mediavine_eligible?(site) do
        Sites.update_site(site, %{mediavine_approved: true})
        Logger.info("[Orchestrator] #{site.domain} now Mediavine eligible (#{site.monthly_pageviews} PV)")
      end
    end)
  end

  defp schedule_next_run do
    Process.send_after(self(), :scheduled_run, @schedule_interval)
  end

  defp schedule_daily_tasks do
    # Run daily tasks every 24 hours
    Process.send_after(self(), :daily_tasks, :timer.hours(24))
  end
end
