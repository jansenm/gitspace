defmodule Gitspace.Index.WorkspaceLabel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspace_labels" do
    field(:label, :string)

    belongs_to(:workspace, Gitspace.Index.Workspace, type: :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:workspace_id, :label])
    |> validate_required([:workspace_id, :label])
    |> unique_constraint([:workspace_id, :label])
  end
end
