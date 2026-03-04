defmodule ContentNetwork.Content.Article do
  use Ecto.Schema
  import Ecto.Changeset

  schema "articles" do
    belongs_to :site, ContentNetwork.Sites.Site
    field :title, :string
    field :slug, :string
    field :content_markdown, :string
    field :content_html, :string
    field :meta_description, :string
    field :target_keyword, :string
    field :secondary_keywords, {:array, :string}, default: []
    field :word_count, :integer
    field :status, Ecto.Enum, values: [:draft, :published, :updating, :archived]
    field :published_at, :utc_datetime
    field :pageviews, :integer, default: 0
    field :affiliate_clicks, :integer, default: 0
    field :affiliate_revenue_cents, :integer, default: 0
    field :seo_score, :integer, default: 0
    field :search_position, :float
    field :r2_key, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields ~w(site_id title slug target_keyword)a
  @optional_fields ~w(content_markdown content_html meta_description secondary_keywords
    word_count status published_at pageviews affiliate_clicks affiliate_revenue_cents
    seo_score search_position r2_key metadata)a

  def changeset(article, attrs) do
    article
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, min: 10, max: 255)
    |> validate_length(:slug, min: 3, max: 255)
    |> validate_length(:meta_description, max: 160)
    |> validate_format(:slug, ~r/^[a-z0-9\-]+$/, message: "must contain only lowercase letters, numbers, and hyphens")
    |> validate_number(:word_count, greater_than: 0)
    |> validate_number(:seo_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:site_id)
    |> unique_constraint([:site_id, :slug])
  end

  def publish_changeset(article, attrs) do
    article
    |> cast(attrs, [:status, :published_at, :content_html, :content_markdown, :word_count, :r2_key])
    |> put_change(:status, :published)
    |> put_change(:published_at, DateTime.truncate(DateTime.utc_now(), :second))
  end

  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  def content_type(%__MODULE__{metadata: %{"content_type" => type}}), do: type
  def content_type(%__MODULE__{}), do: "informational"
end
