defmodule Gitspace.Index.Checkout do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "checkouts" do
    field(:path, :string)
    field(:kind, :string, default: "worktree")
    field(:source, :string, default: "managed")
    field(:state, :string, default: "ok")
    field(:branch, :string)
    field(:head_sha, :string)
    field(:detached, :boolean, default: false)
    field(:dirty, :integer)
    field(:ahead, :integer)
    field(:behind, :integer)
    field(:untracked, :integer)
    field(:unpushed, :integer)
    field(:last_status_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:created_by, :string)

    belongs_to(:repository, Gitspace.Index.Repository, type: :binary_id)

    has_many(:workspace_members, Gitspace.Index.WorkspaceMember)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(repository_id path kind source state)a
  @optional ~w(branch head_sha detached dirty ahead behind untracked unpushed last_status_at
               last_seen_at created_by)a

  def changeset(checkout, attrs) do
    checkout
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, ~w(worktree clone))
    |> validate_inclusion(:source, ~w(managed external))
    |> validate_inclusion(:state, ~w(ok missing broken unavailable detached))
    |> unique_constraint(:path)
  end
end
