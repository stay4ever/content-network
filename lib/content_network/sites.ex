defmodule ContentNetwork.Sites do
  @moduledoc """
  Context module for managing content network sites.
  """
  import Ecto.Query
  alias ContentNetwork.Repo
  alias ContentNetwork.Sites.Site

  def list_sites do
    Site
    |> order_by(desc: :monthly_revenue_cents)
    |> Repo.all()
  end

  def list_active_sites do
    Site
    |> where([s], s.status in [:growing, :monetized, :scaling, :mature])
    |> order_by(desc: :monthly_revenue_cents)
    |> Repo.all()
  end

  def get_site!(id), do: Repo.get!(Site, id)

  def get_site_by_domain(domain) do
    Repo.get_by(Site, domain: domain)
  end

  def create_site(attrs \\ %{}) do
    %Site{}
    |> Site.changeset(attrs)
    |> Repo.insert()
  end

  def update_site(%Site{} = site, attrs) do
    site
    |> Site.changeset(attrs)
    |> Repo.update()
  end

  def increment_article_count(%Site{} = site) do
    Site
    |> where(id: ^site.id)
    |> Repo.update_all(inc: [article_count: 1])
  end

  def update_revenue(%Site{} = site, revenue_cents) do
    update_site(site, %{
      monthly_revenue_cents: site.monthly_revenue_cents + revenue_cents,
      total_revenue_cents: site.total_revenue_cents + revenue_cents
    })
  end

  def update_pageviews(%Site{} = site, pageviews) do
    update_site(site, %{monthly_pageviews: pageviews})
  end

  def sites_by_status(status) do
    Site
    |> where([s], s.status == ^status)
    |> Repo.all()
  end

  def total_monthly_revenue do
    Site
    |> select([s], sum(s.monthly_revenue_cents))
    |> Repo.one() || 0
  end

  def total_pageviews do
    Site
    |> select([s], sum(s.monthly_pageviews))
    |> Repo.one() || 0
  end

  def aggregate_metrics do
    sites = list_sites()

    %{
      total_sites: length(sites),
      total_articles: Enum.sum(Enum.map(sites, & &1.article_count)),
      total_monthly_revenue_cents: Enum.sum(Enum.map(sites, & &1.monthly_revenue_cents)),
      total_monthly_pageviews: Enum.sum(Enum.map(sites, & &1.monthly_pageviews)),
      total_email_subscribers: Enum.sum(Enum.map(sites, & &1.email_subscribers)),
      sites_by_status: Enum.frequencies_by(sites, & &1.status),
      mediavine_sites: Enum.count(sites, & &1.mediavine_approved),
      avg_domain_authority: safe_avg(sites, & &1.domain_authority)
    }
  end

  defp safe_avg([], _fun), do: 0

  defp safe_avg(list, fun) do
    values = Enum.map(list, fun)
    div(Enum.sum(values), length(values))
  end
end
