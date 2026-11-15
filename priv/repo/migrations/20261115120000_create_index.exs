defmodule Gitspace.Repo.Migrations.CreateIndex do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :remote_url, :string, null: false
      add :remote_key, :string, null: false
      add :bare_path, :string
      add :default_branch, :string
      add :state, :string, null: false, default: "managed"
      add :last_fetched_at, :utc_datetime_usec
      add :last_fetch_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:slug])
    create unique_index(:repositories, [:remote_key])
    create unique_index(:repositories, [:bare_path])

    create table(:checkouts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :path, :string, null: false
      add :kind, :string, null: false, default: "worktree"
      add :source, :string, null: false, default: "managed"
      add :state, :string, null: false, default: "ok"
      add :branch, :string
      add :head_sha, :string
      add :detached, :boolean, null: false, default: false
      add :dirty, :integer
      add :ahead, :integer
      add :behind, :integer
      add :untracked, :integer
      add :unpushed, :integer
      add :last_status_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:checkouts, [:path])
    create index(:checkouts, [:repository_id])
    create index(:checkouts, [:source])
    create index(:checkouts, [:state])

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :state, :string, null: false, default: "active"
      add :marker_path, :string
      add :torn_down_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:name], where: "state = 'active'",
                                             name: :workspaces_active_name_index
    )

    create table(:workspace_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :checkout_id, references(:checkouts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :ownership, :string, null: false
      add :role, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_members, [:workspace_id, :checkout_id])
    create unique_index(:workspace_members, [:workspace_id, :repository_id],
             name: :workspace_members_workspace_repository_index
           )

    create index(:workspace_members, [:checkout_id])

    create table(:workspace_labels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_labels, [:workspace_id, :label])
  end
end
