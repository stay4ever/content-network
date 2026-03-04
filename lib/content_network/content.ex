defmodule ContentNetwork.Content do
  @moduledoc """
  Context module for content management — articles and revenue events.
  """
  import Ecto.Query
  alias ContentNetwork.Repo
  alias ContentNetwork.Content.{Article, RevenueEvent}

  # --- Articles ---

  def list_articles(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)
    site_id = Keyword.get(opts, :site_id)

    Article
    |> maybe_filter_status(status)
    |> maybe_filter_site(site_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent_articles(limit \\ 20) do
    Article
    |> where([a], a.status == :published)
    |> order_by(desc: :published_at)
    |> limit(^limit)
    |> preload(:site)
    |> Repo.all()
  end

  def list_top_articles(limit \\ 10) do
    Article
    |> where([a], a.status == :published)
    |> order_by(desc: :affiliate_revenue_cents)
    |> limit(^limit)
    |> preload(:site)
    |> Repo.all()
  end

  def get_article!(id), do: Repo.get!(Article, id) |> Repo.preload(:site)

  def get_article_by_slug(site_id, slug) do
    Article
    |> where([a], a.site_id == ^site_id and a.slug == ^slug)
    |> Repo.one()
  end

  def create_article(attrs) do
    %Article{}
    |> Article.changeset(attrs)
    |> Repo.insert()
  end

  def update_article(%Article{} = article, attrs) do
    article
    |> Article.changeset(attrs)
    |> Repo.update()
  end

  def publish_article(%Article{} = article, attrs) do
    article
    |> Article.publish_changeset(attrs)
    |> Repo.update()
  end

  def articles_needing_seo_review(limit \\ 10) do
    threshold = DateTime.add(DateTime.utc_now(), -7 * 86400, :second)

    Article
    |> where([a], a.status == :published)
    |> where([a], a.seo_score < 70 or is_nil(a.seo_score))
    |> where([a], a.published_at < ^threshold)
    |> order_by(asc: :seo_score)
    |> limit(^limit)
    |> preload(:site)
    |> Repo.all()
  end

  def articles_for_affiliate_optimization(limit \\ 10) do
    Article
    |> where([a], a.status == :published)
    |> where([a], a.pageviews > 100 and a.affiliate_clicks == 0)
    |> order_by(desc: :pageviews)
    |> limit(^limit)
    |> preload(:site)
    |> Repo.all()
  end

  def article_count_by_site(site_id) do
    Article
    |> where([a], a.site_id == ^site_id)
    |> Repo.aggregate(:count)
  end

  def total_article_count do
    Repo.aggregate(Article, :count)
  end

  # --- Revenue Events ---

  def create_revenue_event(attrs) do
    %RevenueEvent{}
    |> RevenueEvent.changeset(attrs)
    |> Repo.insert()
  end

  def revenue_by_type(site_id, days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    RevenueEvent
    |> where([r], r.site_id == ^site_id)
    |> where([r], r.inserted_at >= ^since)
    |> group_by([r], r.type)
    |> select([r], {r.type, sum(r.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  def total_revenue(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    RevenueEvent
    |> where([r], r.inserted_at >= ^since)
    |> select([r], sum(r.amount_cents))
    |> Repo.one() || 0
  end

  def revenue_breakdown(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    RevenueEvent
    |> where([r], r.inserted_at >= ^since)
    |> group_by([r], r.type)
    |> select([r], {r.type, sum(r.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  def daily_revenue(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    RevenueEvent
    |> where([r], r.inserted_at >= ^since)
    |> group_by([r], fragment("date(?)", r.inserted_at))
    |> select([r], {fragment("date(?)", r.inserted_at), sum(r.amount_cents)})
    |> order_by([r], fragment("date(?)", r.inserted_at))
    |> Repo.all()
  end

  # --- Private ---

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [a], a.status == ^status)

  defp maybe_filter_site(query, nil), do: query
  defp maybe_filter_site(query, site_id), do: where(query, [a], a.site_id == ^site_id)
end
