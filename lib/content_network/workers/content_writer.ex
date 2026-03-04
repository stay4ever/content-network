defmodule ContentNetwork.Workers.ContentWriter do
  @moduledoc """
  Core content engine. Generates SEO-optimized articles using Claude.

  Pipeline: keyword research -> outline -> full article -> internal linking -> publish

  Generates 2000-3000 word articles with proper H2/H3 structure and
  natural affiliate product mentions. Stores markdown + HTML to R2.
  """
  use Oban.Worker,
    queue: :content,
    max_attempts: 3,
    unique: [period: 300, fields: [:args]]

  require Logger

  alias ContentNetwork.{Content, Sites, ClaudeClient, Storage}
  alias ContentNetwork.Content.Article

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    site_id = args["site_id"]
    keyword = args["target_keyword"]
    content_type = args["content_type"] || "informational"
    secondary_keywords = args["secondary_keywords"] || []

    site = Sites.get_site!(site_id)

    Logger.info("[ContentWriter] Starting article for site=#{site.domain} keyword=#{keyword}")

    with {:ok, outline} <- generate_outline(site, keyword, content_type, secondary_keywords),
         {:ok, article_data} <- generate_full_article(site, keyword, outline, content_type, secondary_keywords),
         {:ok, article_data} <- add_internal_links(site, article_data),
         {:ok, article} <- save_article(site, keyword, content_type, secondary_keywords, article_data),
         {:ok, _} <- upload_to_r2(site, article, article_data) do
      Sites.increment_article_count(site)
      broadcast_article_published(site, article)
      Logger.info("[ContentWriter] Published article=#{article.slug} site=#{site.domain} words=#{article_data.word_count}")
      {:ok, article.id}
    else
      {:error, reason} ->
        Logger.error("[ContentWriter] Failed for site=#{site.domain} keyword=#{keyword}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp generate_outline(site, keyword, content_type, secondary_keywords) do
    prompt = """
    You are an expert SEO content strategist. Create a detailed article outline for:

    Site niche: #{site.niche}
    Target keyword: #{keyword}
    Content type: #{content_type}
    Secondary keywords: #{Enum.join(secondary_keywords, ", ")}

    Requirements:
    - Article should be 2000-3000 words
    - Use proper H2/H3 heading structure (6-10 H2 sections)
    - Include a compelling introduction with the keyword in the first paragraph
    - For "buyer_intent" type: include product comparison sections, pros/cons, pricing
    - For "comparison" type: include side-by-side analysis, winner section
    - For "informational" type: include actionable tips, expert insights
    - Include FAQ section (3-5 questions targeting People Also Ask)
    - Include a conclusion with call-to-action

    Return the outline as a structured list with:
    - title: SEO-optimized title (55-65 chars)
    - meta_description: compelling description (145-155 chars)
    - sections: list of {heading, subheadings, key_points, word_target}
    - affiliate_opportunities: natural places to mention products

    Format as JSON.
    """

    case ClaudeClient.complete(prompt, max_tokens: 2048) do
      {:ok, response} ->
        outline = parse_outline(response)
        {:ok, outline}

      {:error, reason} ->
        {:error, {:outline_failed, reason}}
    end
  end

  defp generate_full_article(site, keyword, outline, content_type, secondary_keywords) do
    affiliate_context =
      if site.affiliate_programs != [] do
        "Naturally mention products from these affiliate programs: #{Enum.join(site.affiliate_programs, ", ")}. " <>
          "Use product names contextually without being pushy. Include 2-4 product mentions."
      else
        "Include generic product category mentions that could later have affiliate links added."
      end

    prompt = """
    You are an expert content writer specializing in #{site.niche}. Write a complete, high-quality article.

    Target keyword: #{keyword}
    Secondary keywords: #{Enum.join(secondary_keywords, ", ")}
    Content type: #{content_type}
    Article outline: #{Jason.encode!(outline)}

    #{affiliate_context}

    Writing requirements:
    - Write 2000-3000 words of genuinely helpful, expert-level content
    - Use the target keyword naturally 4-8 times throughout the article
    - Sprinkle secondary keywords naturally
    - Write in a conversational but authoritative tone
    - Use short paragraphs (2-3 sentences max)
    - Include bullet points and numbered lists where appropriate
    - Use proper Markdown formatting with ## for H2 and ### for H3
    - Include a compelling hook in the introduction
    - Add data points, statistics, or expert quotes where relevant
    - End each major section with a transition to the next
    - FAQ section should use ### for each question
    - Conclusion should summarize key takeaways and include a clear CTA

    Format the entire article in Markdown. Start with the title as # heading.
    """

    case ClaudeClient.complete(prompt, max_tokens: 8192) do
      {:ok, markdown} ->
        html = Earmark.as_html!(markdown, code_class_prefix: "language-")
        word_count = markdown |> String.split(~r/\s+/) |> length()

        {:ok,
         %{
           title: extract_title(markdown, outline),
           markdown: markdown,
           html: html,
           word_count: word_count,
           meta_description: Map.get(outline, "meta_description", generate_meta_description(markdown))
         }}

      {:error, reason} ->
        {:error, {:article_failed, reason}}
    end
  end

  defp add_internal_links(site, article_data) do
    existing_articles =
      Content.list_articles(site_id: site.id, status: :published, limit: 20)

    if existing_articles == [] do
      {:ok, article_data}
    else
      link_targets =
        existing_articles
        |> Enum.map(fn a -> %{title: a.title, slug: a.slug, keyword: a.target_keyword} end)
        |> Enum.take(10)

      prompt = """
      Add internal links to this Markdown article. Here are existing articles on the same site:

      #{Jason.encode!(link_targets)}

      Article to add links to:
      #{article_data.markdown}

      Rules:
      - Add 2-5 internal links naturally within the text
      - Use descriptive anchor text (not "click here")
      - Link format: [anchor text](/articles/SLUG)
      - Only link where contextually relevant
      - Don't link the same article twice
      - Return the complete article with links added
      """

      case ClaudeClient.complete(prompt, max_tokens: 8192) do
        {:ok, linked_markdown} ->
          linked_html = Earmark.as_html!(linked_markdown, code_class_prefix: "language-")
          {:ok, %{article_data | markdown: linked_markdown, html: linked_html}}

        {:error, _} ->
          {:ok, article_data}
      end
    end
  end

  defp save_article(site, keyword, content_type, secondary_keywords, article_data) do
    slug = Article.slugify(article_data.title)

    attrs = %{
      site_id: site.id,
      title: article_data.title,
      slug: slug,
      content_markdown: article_data.markdown,
      content_html: article_data.html,
      meta_description: article_data.meta_description,
      target_keyword: keyword,
      secondary_keywords: secondary_keywords,
      word_count: article_data.word_count,
      status: :published,
      published_at: DateTime.truncate(DateTime.utc_now(), :second),
      seo_score: calculate_initial_seo_score(article_data, keyword),
      metadata: %{"content_type" => content_type}
    }

    Content.create_article(attrs)
  end

  defp upload_to_r2(site, article, article_data) do
    r2_key = "sites/#{site.domain}/articles/#{article.slug}.md"

    case Storage.put_object(r2_key, article_data.markdown, content_type: "text/markdown") do
      {:ok, _} ->
        Content.update_article(article, %{r2_key: r2_key})

      {:error, reason} ->
        Logger.warning("[ContentWriter] R2 upload failed for #{r2_key}: #{inspect(reason)}")
        {:ok, article}
    end
  end

  defp parse_outline(response) do
    case Jason.decode(response) do
      {:ok, data} -> data
      {:error, _} -> extract_outline_from_text(response)
    end
  end

  defp extract_outline_from_text(text) do
    %{
      "title" => extract_first_line(text),
      "meta_description" => String.slice(text, 0, 155),
      "sections" => [],
      "affiliate_opportunities" => []
    }
  end

  defp extract_title(markdown, outline) do
    case Regex.run(~r/^#\s+(.+)$/m, markdown) do
      [_, title] -> String.trim(title)
      _ -> Map.get(outline, "title", "Untitled Article")
    end
  end

  defp extract_first_line(text) do
    text |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end

  defp generate_meta_description(markdown) do
    markdown
    |> String.replace(~r/^#.*$/m, "")
    |> String.replace(~r/[*_`\[\]]/, "")
    |> String.trim()
    |> String.split(~r/[.!?]/)
    |> Enum.take(2)
    |> Enum.join(". ")
    |> String.slice(0, 155)
    |> Kernel.<>("...")
  end

  defp calculate_initial_seo_score(article_data, keyword) do
    score = 0

    # Title contains keyword
    score = if String.contains?(String.downcase(article_data.title), String.downcase(keyword)), do: score + 15, else: score

    # Meta description exists and is proper length
    meta = article_data.meta_description || ""
    score = if String.length(meta) >= 120 and String.length(meta) <= 160, do: score + 10, else: score

    # Word count in target range
    score = cond do
      article_data.word_count >= 2000 and article_data.word_count <= 3000 -> score + 20
      article_data.word_count >= 1500 -> score + 10
      true -> score + 5
    end

    # Keyword density (approximate)
    keyword_count =
      article_data.markdown
      |> String.downcase()
      |> String.split(String.downcase(keyword))
      |> length()
      |> Kernel.-(1)

    density = keyword_count / max(article_data.word_count / 100, 1)
    score = cond do
      density >= 1.0 and density <= 3.0 -> score + 15
      density >= 0.5 -> score + 10
      true -> score + 5
    end

    # Has H2 headings
    h2_count = length(Regex.scan(~r/^##\s/m, article_data.markdown))
    score = cond do
      h2_count >= 5 -> score + 15
      h2_count >= 3 -> score + 10
      true -> score + 5
    end

    # Has internal links
    link_count = length(Regex.scan(~r/\[.+?\]\(.+?\)/, article_data.markdown))
    score = if link_count >= 2, do: score + 10, else: score + 3

    # Has lists
    list_count = length(Regex.scan(~r/^[\-\*\d]\s/m, article_data.markdown))
    score = if list_count >= 3, do: score + 10, else: score + 3

    # Cap at 100
    min(score, 100)
  end

  defp broadcast_article_published(site, article) do
    Phoenix.PubSub.broadcast(
      ContentNetwork.PubSub,
      "content:updates",
      {:article_published, %{site: site.domain, article: article.title, slug: article.slug}}
    )
  end
end
