defmodule Gitspace.Index.Repository do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "repositories" do
    field(:slug, :string)
    field(:remote_url, :string)
    field(:remote_key, :string)
    field(:bare_path, :string)
    field(:default_branch, :string)
    field(:state, :string, default: "managed")
    field(:alias_source, :string, default: "auto")
    field(:last_fetched_at, :utc_datetime_usec)
    field(:last_fetch_error, :string)

    has_many(:checkouts, Gitspace.Index.Checkout)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(slug remote_url remote_key state)a
  @optional ~w(bare_path default_branch alias_source last_fetched_at last_fetch_error)a

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:alias_source, ~w(auto explicit))
    |> unique_constraint(:slug)
    |> unique_constraint(:remote_key)
    |> unique_constraint(:bare_path)
  end
end
