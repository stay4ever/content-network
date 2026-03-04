defmodule ContentNetwork.Sites.Site do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sites" do
    field :name, :string
    field :domain, :string
    field :niche, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:setup, :growing, :monetized, :scaling, :mature]
    field :monthly_pageviews, :integer, default: 0
    field :monthly_revenue_cents, :integer, default: 0
    field :total_revenue_cents, :integer, default: 0
    field :article_count, :integer, default: 0
    field :email_subscribers, :integer, default: 0
    field :domain_authority, :integer, default: 0
    field :affiliate_programs, {:array, :string}, default: []
    field :mediavine_approved, :boolean, default: false
    field :metadata, :map, default: %{}

    has_many :articles, ContentNetwork.Content.Article
    has_many :revenue_events, ContentNetwork.Content.RevenueEvent

    timestamps()
  end

  @required_fields ~w(name domain niche)a
  @optional_fields ~w(description status monthly_pageviews monthly_revenue_cents
    total_revenue_cents article_count email_subscribers domain_authority
    affiliate_programs mediavine_approved metadata)a

  def changeset(site, attrs) do
    site
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:domain, min: 3, max: 255)
    |> validate_format(:domain, ~r/^[a-z0-9\-\.]+\.[a-z]{2,}$/i, message: "must be a valid domain")
    |> validate_number(:monthly_pageviews, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_revenue_cents, greater_than_or_equal_to: 0)
    |> validate_number(:domain_authority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:domain)
  end

  def status_changeset(site, status) do
    site
    |> cast(%{status: status}, [:status])
    |> validate_inclusion(:status, [:setup, :growing, :monetized, :scaling, :mature])
  end

  def revenue_tier(%__MODULE__{monthly_revenue_cents: rev}) when rev >= 1_400_000, do: :scaling
  def revenue_tier(%__MODULE__{monthly_revenue_cents: rev}) when rev >= 500_000, do: :monetized
  def revenue_tier(%__MODULE__{monthly_revenue_cents: rev}) when rev >= 100_000, do: :growing
  def revenue_tier(%__MODULE__{}), do: :setup

  def mediavine_eligible?(%__MODULE__{monthly_pageviews: pv}), do: pv >= 50_000
end
