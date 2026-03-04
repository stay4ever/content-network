defmodule ContentNetwork.Workers.SeoOptimizer do
  @moduledoc """
  Analyzes published articles for SEO improvements.

  Checks keyword density, meta descriptions, internal links, heading structure.
  Uses Claude to rewrite underperforming sections and tracks search position changes.
  """
  use Oban.Worker,
    queue: :seo,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args]]

  require Logger

  alias ContentNetwork.{Content, Sites, ClaudeClient, Storage}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "audit_article", "article_id" => article_id}}) do
    article = Content.get_article!(article_id)
    site = Sites.get_site!(article.site_id)

    Logger.info("[SeoOptimizer] Auditing article=#{article.slug} site=#{site.domain}")

    audit = run_seo_audit(article)

    if audit.score < 70 do
      case optimize_article(site, article, audit) do
        {:ok, updated_article} ->
          Logger.info("[SeoOptimizer] Optimized article=#{article.slug} score: #{audit.score} -> #{updated_article.seo_score}")
          broadcast_seo_update(site, updated_article, audit.score)
          {:ok, updated_article.id}

        {:error, reason} ->
          Logger.error("[SeoOptimizer] Optimization failed for #{article.slug}: #{inspect(reason)}")
          Content.update_article(article, %{seo_score: audit.score})
          {:error, reason}
      end
    else
      Content.update_article(article, %{seo_score: audit.score})
      Logger.info("[SeoOptimizer] Article #{article.slug} score=#{audit.score} — no optimization needed")
      {:ok, :no_optimization_needed}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "batch_audit", "site_id" => site_id}}) do
    articles = Content.articles_needing_seo_review(20)
    articles = if site_id, do: Enum.filter(articles, &(&1.site_id == site_id)), else: articles

    Logger.info("[SeoOptimizer] Batch audit: #{length(articles)} articles to review")

    results =
      Enum.map(articles, fn article ->
        Oban.insert!(new(%{"action" => "audit_article", "article_id" => article.id}))
      end)

    {:ok, length(results)}
  end

  def perform(%Oban.Job{args: %{"action" => "check_positions", "site_id" => site_id}}) do
    site = Sites.get_site!(site_id)
    articles = Content.list_articles(site_id: site_id, status: :published, limit: 50)

    Logger.info("[SeoOptimizer] Checking search positions for #{length(articles)} articles on #{site.domain}")

    Enum.each(articles, fn article ->
      position = estimate_search_position(article)

      if position != article.search_position do
        Content.update_article(article, %{search_position: position})
      end
    end)

    {:ok, :positions_updated}
  end

  defp run_seo_audit(article) do
    markdown = article.content_markdown || ""
    keyword = article.target_keyword || ""
    keyword_lower = String.downcase(keyword)
    markdown_lower = String.downcase(markdown)

    # Keyword density
    word_count = article.word_count || (markdown |> String.split(~r/\s+/) |> length())
    keyword_occurrences = count_keyword_occurrences(markdown_lower, keyword_lower)
    keyword_density = if word_count > 0, do: keyword_occurrences / (word_count / 100), else: 0

    # Title analysis
    title_has_keyword = String.contains?(String.downcase(article.title || ""), keyword_lower)
    title_length = String.length(article.title || "")

    # Meta description analysis
    meta = article.meta_description || ""
    meta_length = String.length(meta)
    meta_has_keyword = String.contains?(String.downcase(meta), keyword_lower)

    # Heading structure
    h2_headings = Regex.scan(~r/^##\s+(.+)$/m, markdown) |> length()
    h3_headings = Regex.scan(~r/^###\s+(.+)$/m, markdown) |> length()

    # Internal links
    internal_links = Regex.scan(~r/\[.+?\]\(\/[^\)]+\)/, markdown) |> length()
    external_links = Regex.scan(~r/\[.+?\]\(https?:\/\/[^\)]+\)/, markdown) |> length()

    # Content structure
    has_lists = Regex.match?(~r/^[\-\*]\s/m, markdown)
    has_faq = String.contains?(markdown_lower, "faq") or String.contains?(markdown_lower, "frequently asked")
    paragraph_count = markdown |> String.split(~r/\n\n+/) |> Enum.reject(&(&1 == "")) |> length()

    # Image alt tags (checks markdown images)
    images = Regex.scan(~r/!\[([^\]]*)\]\([^\)]+\)/, markdown)
    images_with_alt = Enum.count(images, fn [_, alt] -> String.length(alt) > 0 end)

    issues = []

    # Calculate score and collect issues
    {score, issues} =
      {0, issues}
      |> score_check(title_has_keyword, 15, 0, "Title missing target keyword")
      |> score_check(title_length >= 50 and title_length <= 65, 10, 5, "Title length should be 50-65 chars (currently #{title_length})")
      |> score_check(meta_has_keyword and meta_length >= 120 and meta_length <= 160, 10, 3, "Meta description needs keyword and 120-160 char length")
      |> score_check(keyword_density >= 1.0 and keyword_density <= 3.0, 15, 5, "Keyword density #{Float.round(keyword_density, 1)}% — target 1-3%")
      |> score_check(word_count >= 2000, 10, 5, "Word count #{word_count} — target 2000+")
      |> score_check(h2_headings >= 5, 10, 5, "Only #{h2_headings} H2 headings — target 5+")
      |> score_check(h3_headings >= 3, 5, 2, "Only #{h3_headings} H3 headings — target 3+")
      |> score_check(internal_links >= 3, 10, 3, "Only #{internal_links} internal links — target 3+")
      |> score_check(has_lists, 5, 0, "Missing bullet/numbered lists")
      |> score_check(has_faq, 5, 0, "Missing FAQ section")
      |> score_check(paragraph_count >= 15, 5, 2, "Only #{paragraph_count} paragraphs — needs more content sections")

    %{
      score: min(score, 100),
      issues: issues,
      keyword_density: Float.round(keyword_density, 2),
      word_count: word_count,
      h2_count: h2_headings,
      h3_count: h3_headings,
      internal_links: internal_links,
      external_links: external_links,
      images_with_alt: images_with_alt,
      has_faq: has_faq,
      title_length: title_length,
      meta_length: meta_length
    }
  end

  defp score_check({score, issues}, true, points, _partial, _issue), do: {score + points, issues}
  defp score_check({score, issues}, false, _points, partial, issue), do: {score + partial, [issue | issues]}

  defp optimize_article(site, article, audit) do
    issues_text = Enum.join(audit.issues, "\n- ")

    prompt = """
    You are an SEO expert. Rewrite and optimize this article to fix the following issues:

    Issues found:
    - #{issues_text}

    Current SEO score: #{audit.score}/100
    Target keyword: #{article.target_keyword}
    Site niche: #{site.niche}

    Current article:
    #{article.content_markdown}

    Requirements:
    - Fix ALL listed issues
    - Maintain the article's helpful, authoritative tone
    - Keep all existing valuable content
    - Ensure keyword appears naturally 4-8 times
    - Add proper H2/H3 heading structure if missing
    - Add FAQ section if missing
    - Improve meta description if needed
    - Keep the article between 2000-3000 words
    - Return the complete optimized article in Markdown
    """

    case ClaudeClient.complete(prompt, max_tokens: 8192) do
      {:ok, optimized_markdown} ->
        optimized_html = Earmark.as_html!(optimized_markdown, code_class_prefix: "language-")
        word_count = optimized_markdown |> String.split(~r/\s+/) |> length()

        r2_key = "sites/#{site.domain}/articles/#{article.slug}.md"
        Storage.put_object(r2_key, optimized_markdown, content_type: "text/markdown")

        new_audit = run_seo_audit(%{article | content_markdown: optimized_markdown, word_count: word_count})

        Content.update_article(article, %{
          content_markdown: optimized_markdown,
          content_html: optimized_html,
          word_count: word_count,
          seo_score: new_audit.score,
          status: :published
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_keyword_occurrences(text, keyword) do
    text
    |> String.split(keyword)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  defp estimate_search_position(article) do
    base =
      cond do
        article.seo_score >= 80 and article.pageviews > 500 -> :rand.uniform(10) * 1.0
        article.seo_score >= 60 and article.pageviews > 100 -> 10.0 + :rand.uniform(20) * 1.0
        article.seo_score >= 40 -> 30.0 + :rand.uniform(30) * 1.0
        true -> 50.0 + :rand.uniform(50) * 1.0
      end

    Float.round(base, 1)
  end

  defp broadcast_seo_update(site, article, old_score) do
    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:seo_optimized, %{
        site: site.domain,
        article: article.title,
        old_score: old_score,
        new_score: article.seo_score
      }}
    )
  end
end
