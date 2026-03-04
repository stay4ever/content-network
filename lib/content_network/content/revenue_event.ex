defmodule ContentNetwork.Content.RevenueEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "content_revenue_events" do
    belongs_to :site, ContentNetwork.Sites.Site
    belongs_to :article, ContentNetwork.Content.Article, on_replace: :nilify
    field :type, Ecto.Enum, values: [:affiliate, :display_ad, :sponsored, :email_product]
    field :amount_cents, :integer
    field :source, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields ~w(site_id type amount_cents source)a
  @optional_fields ~w(article_id metadata)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:site_id)
    |> foreign_key_constraint(:article_id)
  end
end
