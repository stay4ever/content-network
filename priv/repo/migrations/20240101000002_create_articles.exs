defmodule ContentNetwork.Repo.Migrations.CreateArticles do
  use Ecto.Migration

  def change do
    create table(:articles) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :slug, :string, null: false
      add :content_markdown, :text
      add :content_html, :text
      add :meta_description, :string, size: 200
      add :target_keyword, :string, null: false
      add :secondary_keywords, {:array, :string}, null: false, default: []
      add :word_count, :integer
      add :status, :string, null: false, default: "draft"
      add :published_at, :utc_datetime
      add :pageviews, :integer, null: false, default: 0
      add :affiliate_clicks, :integer, null: false, default: 0
      add :affiliate_revenue_cents, :integer, null: false, default: 0
      add :seo_score, :integer, null: false, default: 0
      add :search_position, :float
      add :r2_key, :string
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:articles, [:site_id])
    create unique_index(:articles, [:site_id, :slug])
    create index(:articles, [:status])
    create index(:articles, [:published_at])
    create index(:articles, [:target_keyword])
    create index(:articles, [:seo_score])
    create index(:articles, [:affiliate_revenue_cents])
    create index(:articles, [:pageviews])
  end
end
