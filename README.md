# Content Network

Autonomous Content & Affiliate Network engine built with Elixir/Phoenix.

A fleet of AI-managed niche content sites. Claude writes SEO-optimized articles daily, connects affiliate programs (Amazon Associates, ShareASale, etc.), runs email sequences, and scales to Mediavine display ads.

## Architecture

- **Orchestrator** (GenServer) — Manages content calendar, schedules 3-5 articles/site/day
- **ContentWriter** (Oban) — Generates 2000-3000 word SEO articles via Claude API
- **SeoOptimizer** (Oban) — Audits and rewrites underperforming content
- **AffiliateManager** (Oban) — Tracks commissions, optimizes product placements
- **EmailManager** (Oban) — Welcome sequences, newsletters, promotions
- **AnalyticsWorker** (Oban) — Daily/weekly reports, traffic simulation, growth tracking

## Setup

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Visit `http://localhost:4002`

## Environment Variables

```
DATABASE_URL=ecto://user:pass@host/content_network
SECRET_KEY_BASE=<64+ char secret>
CLAUDE_API_KEY=<anthropic api key>
R2_ACCESS_KEY_ID=<cloudflare r2 key>
R2_SECRET_ACCESS_KEY=<cloudflare r2 secret>
R2_ENDPOINT=<account-id>.r2.cloudflarestorage.com
R2_BUCKET=content-network-assets
```

## Deploy

```bash
fly deploy
```
