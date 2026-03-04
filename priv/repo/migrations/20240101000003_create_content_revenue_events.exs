defmodule ContentNetwork.Repo.Migrations.CreateContentRevenueEvents do
  use Ecto.Migration

  def change do
    create table(:content_revenue_events) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :nilify_all)
      add :type, :string, null: false
      add :amount_cents, :integer, null: false
      add :source, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:content_revenue_events, [:site_id])
    create index(:content_revenue_events, [:article_id])
    create index(:content_revenue_events, [:type])
    create index(:content_revenue_events, [:inserted_at])
    create index(:content_revenue_events, [:site_id, :type, :inserted_at])
  end
end
