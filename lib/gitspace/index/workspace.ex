defmodule Gitspace.Index.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspaces" do
    field(:name, :string)
    field(:description, :string)
    field(:state, :string, default: "active")
    field(:marker_path, :string)
    field(:torn_down_at, :utc_datetime_usec)

    has_many(:members, Gitspace.Index.WorkspaceMember)
    has_many(:labels, Gitspace.Index.WorkspaceLabel)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name state)a
  @optional ~w(description marker_path torn_down_at)a

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:state, ~w(active torn_down))
    # Exqlite reports the Ecto-derived name, not the partial index's SQL name.
    |> unique_constraint(:name)
  end
end
