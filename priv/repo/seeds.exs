alias ContentNetwork.{Repo, Sites.Site}

# Seed initial niche sites for the content network

sites = [
  %{
    name: "TechGear Daily",
    domain: "techgeardaily.com",
    niche: "technology",
    description: "In-depth reviews and buying guides for the latest tech gadgets, laptops, and accessories.",
    status: :growing,
    article_count: 25,
    monthly_pageviews: 8500,
    email_subscribers: 340,
    domain_authority: 15,
    affiliate_programs: ["amazon_associates", "shareasale"],
    metadata: %{"launched_at" => "2024-01-15"}
  },
  %{
    name: "HomeChef Essentials",
    domain: "homechefessentials.com",
    niche: "home",
    description: "Expert kitchen equipment reviews, cooking guides, and home improvement tips.",
    status: :growing,
    article_count: 18,
    monthly_pageviews: 5200,
    email_subscribers: 210,
    domain_authority: 12,
    affiliate_programs: ["amazon_associates"],
    metadata: %{"launched_at" => "2024-02-01"}
  },
  %{
    name: "FitLife Hub",
    domain: "fitlifehub.co",
    niche: "health",
    description: "Science-backed fitness equipment reviews, workout guides, and supplement analysis.",
    status: :setup,
    article_count: 8,
    monthly_pageviews: 1200,
    email_subscribers: 85,
    domain_authority: 8,
    affiliate_programs: ["amazon_associates"],
    metadata: %{"launched_at" => "2024-03-01"}
  },
  %{
    name: "TrailReady Gear",
    domain: "trailreadygear.com",
    niche: "outdoor",
    description: "Comprehensive outdoor and camping gear reviews for hikers, campers, and adventurers.",
    status: :setup,
    article_count: 5,
    monthly_pageviews: 600,
    email_subscribers: 45,
    domain_authority: 5,
    affiliate_programs: ["amazon_associates"],
    metadata: %{"launched_at" => "2024-03-15"}
  },
  %{
    name: "SmartMoney Tools",
    domain: "smartmoneytools.com",
    niche: "finance",
    description: "Honest reviews of financial tools, budgeting apps, and investment platforms.",
    status: :setup,
    article_count: 3,
    monthly_pageviews: 300,
    email_subscribers: 20,
    domain_authority: 3,
    affiliate_programs: [],
    metadata: %{"launched_at" => "2024-04-01"}
  }
]

for attrs <- sites do
  case Repo.get_by(Site, domain: attrs.domain) do
    nil ->
      %Site{}
      |> Site.changeset(attrs)
      |> Repo.insert!()
      IO.puts("Created site: #{attrs.name} (#{attrs.domain})")

    _existing ->
      IO.puts("Site already exists: #{attrs.domain}")
  end
end

IO.puts("\nSeeded #{length(sites)} sites for the content network.")
