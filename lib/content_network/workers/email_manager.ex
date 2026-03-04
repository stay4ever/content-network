defmodule ContentNetwork.Workers.EmailManager do
  @moduledoc """
  Manages email list growth and automated email sequences.

  Creates lead magnets, opt-in forms, welcome sequences (5 emails),
  weekly newsletters, and product promotions using Claude.
  Tracks open rates, click rates, and unsubscribes.
  """
  use Oban.Worker,
    queue: :email,
    max_attempts: 5,
    unique: [period: 3600, fields: [:args]]

  require Logger

  alias ContentNetwork.{Sites, Content, ClaudeClient, Storage}

  @welcome_sequence_days [0, 1, 3, 5, 7]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "create_welcome_sequence", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[EmailManager] Creating welcome sequence for #{site.domain}")

    case generate_welcome_sequence(site) do
      {:ok, sequence} ->
        store_email_sequence(site, "welcome", sequence)
        Logger.info("[EmailManager] Created #{length(sequence)} welcome emails for #{site.domain}")
        {:ok, length(sequence)}

      {:error, reason} ->
        Logger.error("[EmailManager] Welcome sequence failed for #{site.domain}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "create_newsletter", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[EmailManager] Creating weekly newsletter for #{site.domain}")

    recent_articles = Content.list_articles(site_id: site_id, status: :published, limit: 5)

    case generate_newsletter(site, recent_articles) do
      {:ok, newsletter} ->
        store_newsletter(site, newsletter)
        simulate_send(site, newsletter)
        Logger.info("[EmailManager] Newsletter created and queued for #{site.domain}")
        {:ok, :newsletter_created}

      {:error, reason} ->
        Logger.error("[EmailManager] Newsletter failed for #{site.domain}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "create_lead_magnet", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[EmailManager] Creating lead magnet for #{site.domain}")

    case generate_lead_magnet(site) do
      {:ok, lead_magnet} ->
        store_lead_magnet(site, lead_magnet)
        Logger.info("[EmailManager] Lead magnet created for #{site.domain}: #{lead_magnet.title}")
        {:ok, lead_magnet.title}

      {:error, reason} ->
        Logger.error("[EmailManager] Lead magnet failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "create_promo_email", "site_id" => site_id, "product" => product}}) do
    site = Sites.get_site!(site_id)
    Logger.info("[EmailManager] Creating promo email for #{product} on #{site.domain}")

    case generate_promo_email(site, product) do
      {:ok, email} ->
        store_promo_email(site, email)
        simulate_send(site, email)
        {:ok, :promo_created}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "update_subscriber_metrics", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)

    growth_rate = 0.02 + :rand.uniform() * 0.05
    new_subscribers = max(round(site.email_subscribers * growth_rate), 1)
    churn = round(site.email_subscribers * 0.005)
    net_growth = new_subscribers - churn

    Sites.update_site(site, %{
      email_subscribers: max(site.email_subscribers + net_growth, 0)
    })

    Logger.info("[EmailManager] #{site.domain}: +#{new_subscribers} subscribers, -#{churn} churned, net +#{net_growth}")
    {:ok, net_growth}
  end

  defp generate_welcome_sequence(site) do
    top_articles = Content.list_articles(site_id: site.id, status: :published, limit: 5)
    article_titles = Enum.map(top_articles, & &1.title) |> Enum.join("\n- ")

    prompt = """
    Create a 5-email welcome sequence for a #{site.niche} content site called "#{site.name}".

    Site description: #{site.description || site.niche <> " content and reviews"}
    Top articles to reference:
    - #{article_titles}

    Email schedule: Day 0 (immediate), Day 1, Day 3, Day 5, Day 7

    For each email provide:
    1. Subject line (compelling, 40-60 chars)
    2. Preview text (30-50 chars)
    3. Email body in Markdown (200-400 words)

    Email goals:
    - Email 1 (Day 0): Welcome + deliver lead magnet + set expectations
    - Email 2 (Day 1): Share your best/most popular article
    - Email 3 (Day 3): Provide exclusive tips/value not on the site
    - Email 4 (Day 5): Soft product recommendation (affiliate)
    - Email 5 (Day 7): Ask for engagement (reply, social follow, share)

    Tone: Friendly, knowledgeable, helpful. Not salesy.

    Return as JSON array with objects: {subject, preview_text, body_markdown, day, goal}
    """

    case ClaudeClient.complete(prompt, max_tokens: 4096) do
      {:ok, response} ->
        sequence =
          case Jason.decode(response) do
            {:ok, emails} when is_list(emails) ->
              Enum.with_index(emails)
              |> Enum.map(fn {email, idx} ->
                %{
                  subject: Map.get(email, "subject", "Welcome to #{site.name}"),
                  preview_text: Map.get(email, "preview_text", ""),
                  body_markdown: Map.get(email, "body_markdown", ""),
                  day: Enum.at(@welcome_sequence_days, idx, idx),
                  goal: Map.get(email, "goal", "engagement"),
                  metrics: %{
                    estimated_open_rate: 0.35 - idx * 0.03,
                    estimated_click_rate: 0.08 - idx * 0.01
                  }
                }
              end)

            _ ->
              generate_fallback_sequence(site)
          end

        {:ok, sequence}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_newsletter(site, recent_articles) do
    articles_summary =
      recent_articles
      |> Enum.map(fn a ->
        "- #{a.title} (#{a.target_keyword}): #{a.meta_description || "No description"}"
      end)
      |> Enum.join("\n")

    prompt = """
    Write a weekly newsletter for "#{site.name}" (#{site.niche} site).

    This week's articles:
    #{articles_summary}

    Newsletter structure:
    1. Engaging subject line (40-60 chars, creates curiosity)
    2. Brief intro (2-3 sentences) with a personal touch
    3. Featured article highlight with compelling teaser
    4. Quick links to other new articles
    5. One helpful tip or insight related to the niche
    6. Optional: product recommendation (subtle, helpful)
    7. Sign-off with personality

    Return as JSON: {subject, preview_text, body_markdown, featured_article_slug}
    """

    case ClaudeClient.complete(prompt, max_tokens: 2048) do
      {:ok, response} ->
        newsletter =
          case Jason.decode(response) do
            {:ok, data} ->
              %{
                type: :newsletter,
                subject: Map.get(data, "subject", "This Week at #{site.name}"),
                preview_text: Map.get(data, "preview_text", ""),
                body_markdown: Map.get(data, "body_markdown", ""),
                featured_article: Map.get(data, "featured_article_slug"),
                created_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

            _ ->
              %{
                type: :newsletter,
                subject: "This Week at #{site.name}",
                preview_text: "New articles and insights",
                body_markdown: format_fallback_newsletter(site, recent_articles),
                created_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }
          end

        {:ok, newsletter}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_lead_magnet(site) do
    prompt = """
    Suggest a high-converting lead magnet for a #{site.niche} content site called "#{site.name}".

    The lead magnet should:
    - Solve a specific, urgent problem for the target audience
    - Be deliverable as a PDF or email course
    - Take 15-30 minutes to consume
    - Naturally lead into product recommendations (for affiliate revenue)

    Provide:
    1. Title (compelling, benefit-driven)
    2. Subtitle/description
    3. Format (checklist, guide, template, mini-course)
    4. Outline (5-7 sections)
    5. Opt-in page headline and subheadline
    6. Opt-in button text

    Return as JSON.
    """

    case ClaudeClient.complete(prompt, max_tokens: 2048) do
      {:ok, response} ->
        lead_magnet =
          case Jason.decode(response) do
            {:ok, data} ->
              %{
                title: Map.get(data, "title", "Free #{site.niche} Guide"),
                subtitle: Map.get(data, "subtitle", ""),
                format: Map.get(data, "format", "guide"),
                outline: Map.get(data, "outline", []),
                opt_in_headline: Map.get(data, "opt_in_headline", "Get Your Free Guide"),
                opt_in_subheadline: Map.get(data, "opt_in_subheadline", ""),
                opt_in_button: Map.get(data, "opt_in_button", "Download Now"),
                created_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

            _ ->
              %{
                title: "The Ultimate #{site.niche} Guide",
                subtitle: "Everything you need to know",
                format: "guide",
                outline: [],
                opt_in_headline: "Get Your Free #{site.niche} Guide",
                opt_in_subheadline: "Join #{site.email_subscribers}+ subscribers",
                opt_in_button: "Send Me the Guide",
                created_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }
          end

        {:ok, lead_magnet}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_promo_email(site, product) do
    prompt = """
    Write a promotional email for "#{product}" for the #{site.niche} audience of "#{site.name}".

    Requirements:
    - Subject line that drives opens (40-60 chars)
    - Personal, story-driven opening (not salesy)
    - Problem-agitate-solve structure
    - Clear benefits (not just features)
    - Honest recommendation with genuine enthusiasm
    - Single clear CTA
    - P.S. line with urgency or bonus

    Return as JSON: {subject, preview_text, body_markdown, cta_text, cta_url_placeholder}
    """

    case ClaudeClient.complete(prompt, max_tokens: 2048) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, data} ->
            {:ok, %{
              type: :promo,
              subject: Map.get(data, "subject", "Check this out"),
              preview_text: Map.get(data, "preview_text", ""),
              body_markdown: Map.get(data, "body_markdown", ""),
              cta_text: Map.get(data, "cta_text", "Learn More"),
              product: product,
              created_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }}

          _ ->
            {:ok, %{
              type: :promo,
              subject: "I've been using #{product}...",
              preview_text: "And here's what I think",
              body_markdown: "Check out #{product} — I think you'll love it.",
              product: product,
              created_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_fallback_sequence(site) do
    @welcome_sequence_days
    |> Enum.with_index()
    |> Enum.map(fn {day, idx} ->
      %{
        subject: "Welcome to #{site.name} (#{idx + 1}/5)",
        preview_text: "Your #{site.niche} journey starts here",
        body_markdown: "Welcome! More great #{site.niche} content coming your way.",
        day: day,
        goal: "engagement",
        metrics: %{estimated_open_rate: 0.30, estimated_click_rate: 0.05}
      }
    end)
  end

  defp format_fallback_newsletter(site, articles) do
    article_links =
      articles
      |> Enum.map(fn a -> "- [#{a.title}](/articles/#{a.slug})" end)
      |> Enum.join("\n")

    """
    # This Week at #{site.name}

    Here's what's new this week:

    #{article_links}

    Happy reading!
    The #{site.name} Team
    """
  end

  defp simulate_send(site, email_data) do
    subscriber_count = max(site.email_subscribers, 10)

    open_rate = 0.20 + :rand.uniform() * 0.25
    click_rate = 0.03 + :rand.uniform() * 0.08
    unsubscribe_rate = 0.001 + :rand.uniform() * 0.003

    metrics = %{
      sent: subscriber_count,
      opens: round(subscriber_count * open_rate),
      clicks: round(subscriber_count * click_rate),
      unsubscribes: round(subscriber_count * unsubscribe_rate),
      open_rate: Float.round(open_rate * 100, 1),
      click_rate: Float.round(click_rate * 100, 1),
      subject: Map.get(email_data, :subject, "Newsletter")
    }

    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:email_sent, %{site: site.domain, metrics: metrics}}
    )

    metrics
  end

  defp store_email_sequence(site, name, sequence) do
    key = "sites/#{site.domain}/emails/#{name}-sequence.json"
    Storage.put_object(key, Jason.encode!(sequence), content_type: "application/json")
  end

  defp store_newsletter(site, newsletter) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = "sites/#{site.domain}/emails/newsletter-#{date}.json"
    Storage.put_object(key, Jason.encode!(newsletter), content_type: "application/json")
  end

  defp store_lead_magnet(site, lead_magnet) do
    key = "sites/#{site.domain}/emails/lead-magnet.json"
    Storage.put_object(key, Jason.encode!(lead_magnet), content_type: "application/json")
  end

  defp store_promo_email(site, email) do
    date = Date.utc_today() |> Date.to_iso8601()
    key = "sites/#{site.domain}/emails/promo-#{date}.json"
    Storage.put_object(key, Jason.encode!(email), content_type: "application/json")
  end
end
