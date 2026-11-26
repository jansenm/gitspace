defmodule Gitspace.Repo.Migrations.AddRepositoryOriginKind do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :origin_kind, :string, null: false, default: "remote"
    end
  end
end
