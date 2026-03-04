defmodule ContentNetwork.ClaudeClient do
  @moduledoc """
  Claude API wrapper with content-specific functions.

  Provides specialized methods for article writing, SEO optimization,
  email sequence creation, and keyword analysis with proper prompt
  engineering for each content type.
  """
  require Logger

  @base_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  def complete(prompt, opts \\ []) do
    config = Application.get_env(:content_network, __MODULE__, [])
    api_key = Keyword.get(config, :api_key) || System.get_env("CLAUDE_API_KEY")
    model = Keyword.get(opts, :model) || Keyword.get(config, :model, "claude-sonnet-4-20250514")
    max_tokens = Keyword.get(opts, :max_tokens) || Keyword.get(config, :max_tokens, 8192)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[ClaudeClient] No API key configured — returning mock response")
      {:ok, mock_response(prompt)}
    else
      call_api(api_key, model, max_tokens, prompt)
    end
  end

  def write_article(site, keyword, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "informational")
    secondary_keywords = Keyword.get(opts, :secondary_keywords, [])

    prompt = """
    You are an expert content writer for the #{site.niche} niche.
    Write a comprehensive, SEO-optimized article targeting: #{keyword}

    Content type: #{content_type}
    Secondary keywords to include: #{Enum.join(secondary_keywords, ", ")}

    Requirements:
    - 2000-3000 words
    - Proper H2/H3 Markdown heading structure
    - Keyword in title, first paragraph, and naturally throughout
    - Include actionable tips, data points, and expert insights
    - FAQ section with 3-5 questions
    - Compelling meta description (145-155 chars)
    - Short paragraphs (2-3 sentences)
    - Bullet points and numbered lists where appropriate

    Return the complete article in Markdown.
    """

    complete(prompt, max_tokens: 8192)
  end

  def optimize_seo(article_markdown, audit_results) do
    prompt = """
    You are an SEO expert. Optimize this article based on the audit:

    Audit findings:
    #{format_audit(audit_results)}

    Article:
    #{article_markdown}

    Fix all issues while maintaining quality and readability.
    Return the complete optimized article in Markdown.
    """

    complete(prompt, max_tokens: 8192)
  end

  def create_email_sequence(site, sequence_type) do
    prompt = """
    Create a #{sequence_type} email sequence for "#{site.name}" (#{site.niche} niche).

    Site description: #{site.description || site.niche}
    Current subscribers: #{site.email_subscribers}

    Create 5 emails with: subject, preview_text, body (200-400 words each).
    Format as JSON array.
    """

    complete(prompt, max_tokens: 4096)
  end

  def analyze_keyword(keyword) do
    prompt = """
    Analyze this keyword for SEO content creation: "#{keyword}"

    Provide:
    1. Search intent (informational, navigational, commercial, transactional)
    2. Estimated difficulty (1-100)
    3. Content format recommendation
    4. Related keywords (5-10)
    5. Suggested title variations (3-5)
    6. Key topics to cover
    7. Competitor content gaps

    Return as JSON.
    """

    complete(prompt, max_tokens: 2048)
  end

  def generate_meta_description(title, content_summary) do
    prompt = """
    Write a compelling meta description for this article:
    Title: #{title}
    Summary: #{content_summary}

    Requirements:
    - 145-155 characters
    - Include primary keyword naturally
    - Compelling call to action or value proposition
    - No quotation marks

    Return only the meta description text, nothing else.
    """

    complete(prompt, max_tokens: 256)
  end

  def suggest_internal_links(article_content, available_articles) do
    articles_json = Jason.encode!(available_articles)

    prompt = """
    Suggest internal links for this article.

    Available articles to link to:
    #{articles_json}

    Article content:
    #{String.slice(article_content, 0, 3000)}

    Return as JSON array: [{anchor_text, target_slug, context}]
    Suggest 3-5 contextually relevant links.
    """

    complete(prompt, max_tokens: 1024)
  end

  defp call_api(api_key, model, max_tokens, prompt) do
    body =
      Jason.encode!(%{
        model: model,
        max_tokens: max_tokens,
        messages: [
          %{role: "user", content: prompt}
        ]
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", @api_version}
    ]

    case Req.post(@base_url, body: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        content =
          response_body
          |> Map.get("content", [])
          |> Enum.find(%{}, fn block -> block["type"] == "text" end)
          |> Map.get("text", "")

        {:ok, content}

      {:ok, %Req.Response{status: 429}} ->
        Logger.warning("[ClaudeClient] Rate limited — retrying after delay")
        Process.sleep(5000)
        call_api(api_key, model, max_tokens, prompt)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[ClaudeClient] API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[ClaudeClient] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp format_audit(audit) when is_map(audit) do
    issues = Map.get(audit, :issues, Map.get(audit, "issues", []))
    score = Map.get(audit, :score, Map.get(audit, "score", "unknown"))

    """
    Score: #{score}/100
    Issues:
    #{Enum.map(issues, &("- " <> to_string(&1))) |> Enum.join("\n")}
    """
  end

  defp format_audit(audit), do: inspect(audit)

  defp mock_response(prompt) do
    cond do
      String.contains?(prompt, "outline") ->
        Jason.encode!(%{
          "title" => "Complete Guide to #{extract_topic(prompt)}",
          "meta_description" => "Discover everything you need to know about #{extract_topic(prompt)}. Expert tips, reviews, and actionable advice.",
          "sections" => [
            %{"heading" => "Introduction", "word_target" => 200},
            %{"heading" => "What You Need to Know", "word_target" => 400},
            %{"heading" => "Top Recommendations", "word_target" => 500},
            %{"heading" => "How to Choose", "word_target" => 400},
            %{"heading" => "Expert Tips", "word_target" => 400},
            %{"heading" => "FAQ", "word_target" => 300},
            %{"heading" => "Conclusion", "word_target" => 200}
          ],
          "affiliate_opportunities" => ["product comparison section", "top picks list"]
        })

      String.contains?(prompt, "Write a complete") or String.contains?(prompt, "expert content writer") ->
        topic = extract_topic(prompt)
        generate_mock_article(topic)

      String.contains?(prompt, "welcome sequence") or String.contains?(prompt, "email sequence") ->
        Jason.encode!([
          %{"subject" => "Welcome! Here's your free guide", "preview_text" => "Your journey starts now", "body_markdown" => "Welcome aboard!", "day" => 0, "goal" => "welcome"},
          %{"subject" => "Our most popular article", "preview_text" => "Readers love this one", "body_markdown" => "Check out our top content.", "day" => 1, "goal" => "engagement"},
          %{"subject" => "Insider tips you won't find elsewhere", "preview_text" => "Exclusive for subscribers", "body_markdown" => "Here are some exclusive tips.", "day" => 3, "goal" => "value"},
          %{"subject" => "The tool that changed everything", "preview_text" => "Honest recommendation", "body_markdown" => "I want to share something.", "day" => 5, "goal" => "affiliate"},
          %{"subject" => "Quick question for you", "preview_text" => "I'd love to hear from you", "body_markdown" => "Hit reply and let me know.", "day" => 7, "goal" => "engagement"}
        ])

      String.contains?(prompt, "newsletter") ->
        Jason.encode!(%{
          "subject" => "This Week's Best Finds",
          "preview_text" => "New articles and insights",
          "body_markdown" => "# This Week's Roundup\n\nHere's what's new this week.",
          "featured_article_slug" => "getting-started"
        })

      String.contains?(prompt, "Analyze this keyword") ->
        Jason.encode!(%{
          "intent" => "informational",
          "difficulty" => 35,
          "format" => "comprehensive guide",
          "related_keywords" => ["related topic 1", "related topic 2", "related topic 3"],
          "title_variations" => ["Title Option A", "Title Option B", "Title Option C"]
        })

      String.contains?(prompt, "meta description") ->
        "Discover the ultimate guide with expert insights, practical tips, and honest reviews to help you make the best decision."

      true ->
        "Mock response for development. Configure CLAUDE_API_KEY for real content generation."
    end
  end

  defp extract_topic(prompt) do
    cond do
      match = Regex.run(~r/keyword:\s*(.+?)$/m, prompt) -> Enum.at(match, 1, "this topic") |> String.trim()
      match = Regex.run(~r/targeting:\s*(.+?)$/m, prompt) -> Enum.at(match, 1, "this topic") |> String.trim()
      true -> "this topic"
    end
  end

  defp generate_mock_article(topic) do
    """
    # The Complete Guide to #{topic}

    Looking for the best advice on #{topic}? You've come to the right place. In this comprehensive guide, we'll cover everything you need to know.

    ## What You Need to Know About #{topic}

    Understanding #{topic} is essential for making informed decisions. Let's break down the key concepts.

    When it comes to #{topic}, there are several important factors to consider. First, quality matters more than quantity. Second, doing your research pays off in the long run.

    Here are the key takeaways:

    - Research thoroughly before making decisions
    - Compare multiple options side by side
    - Read real user reviews and experiences
    - Consider your specific needs and budget

    ## Top Recommendations for #{topic}

    Based on extensive research and testing, here are our top picks:

    ### Best Overall Choice

    After testing dozens of options, the top recommendation stands out for its reliability, value, and performance. It offers the perfect balance of features and affordability.

    ### Best Budget Option

    If you're on a tighter budget, this option delivers impressive results without breaking the bank. It covers all the essential features most people need.

    ### Best Premium Option

    For those who want the absolute best, this premium choice offers unmatched quality and advanced features that serious enthusiasts will appreciate.

    ## How to Choose the Right Option

    Choosing the right #{topic} depends on several factors:

    1. **Define your needs** — What specific problems are you trying to solve?
    2. **Set a budget** — Know your price range before you start shopping
    3. **Read reviews** — Look for patterns in user feedback
    4. **Compare features** — Make a side-by-side comparison
    5. **Check warranty** — Good products stand behind their quality

    ## Expert Tips and Best Practices

    Here are insider tips from industry experts:

    - Start with the basics and upgrade as needed
    - Don't overspend on features you won't use
    - Look for seasonal sales and discounts
    - Join community forums for real-world advice

    ## Frequently Asked Questions

    ### What is the best #{topic} for beginners?

    For beginners, we recommend starting with a mid-range option that offers a good balance of features and ease of use.

    ### How much should I spend on #{topic}?

    Most people find great options in the $50-200 range, depending on their specific needs and how frequently they'll use it.

    ### Is it worth investing in premium #{topic}?

    If you plan to use it regularly and need advanced features, investing in a premium option can save money long-term through better durability and performance.

    ### Where can I find the best deals?

    Check major retailers during seasonal sales, sign up for price alerts, and compare prices across multiple platforms.

    ## Conclusion

    Choosing the right #{topic} doesn't have to be overwhelming. By following the advice in this guide, you'll be well-equipped to make an informed decision that meets your needs and budget.

    Remember to take your time, do your research, and don't hesitate to reach out with questions. We're here to help you find the perfect solution.

    *Last updated: #{Date.utc_today() |> Date.to_iso8601()}*
    """
  end
end
