defmodule ContentNetwork.Repo.Migrations.CreateSites do
  use Ecto.Migration

  def change do
    create table(:sites) do
      add :name, :string, null: false
      add :domain, :string, null: false
      add :niche, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "setup"
      add :monthly_pageviews, :integer, null: false, default: 0
      add :monthly_revenue_cents, :integer, null: false, default: 0
      add :total_revenue_cents, :integer, null: false, default: 0
      add :article_count, :integer, null: false, default: 0
      add :email_subscribers, :integer, null: false, default: 0
      add :domain_authority, :integer, null: false, default: 0
      add :affiliate_programs, {:array, :string}, null: false, default: []
      add :mediavine_approved, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:sites, [:domain])
    create index(:sites, [:status])
    create index(:sites, [:niche])
    create index(:sites, [:monthly_revenue_cents])
  end
end
