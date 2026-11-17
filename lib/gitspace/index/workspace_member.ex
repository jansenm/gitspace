defmodule Gitspace.Index.WorkspaceMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspace_members" do
    field(:name, :string)
    field(:ownership, :string)
    field(:role, :string)

    belongs_to(:workspace, Gitspace.Index.Workspace, type: :binary_id)
    belongs_to(:checkout, Gitspace.Index.Checkout, type: :binary_id)
    belongs_to(:repository, Gitspace.Index.Repository, type: :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(workspace_id checkout_id repository_id ownership)a
  @optional ~w(name role)a

  def changeset(member, attrs) do
    member
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:ownership, ~w(owned borrowed))
    |> unique_constraint([:workspace_id, :checkout_id])
    |> unique_constraint([:workspace_id, :repository_id],
      name: :workspace_members_workspace_repository_index
    )
    |> unique_constraint([:workspace_id, :name],
      name: :workspace_members_workspace_name_index
    )
  end
end
