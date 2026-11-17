defmodule Gitspace.Repo.Migrations.AddAliasMetadata do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :alias_source, :string, null: false, default: "auto"
    end

    alter table(:workspace_members) do
      add :name, :string
    end

    create unique_index(:workspace_members, [:workspace_id, :name],
             where: "name IS NOT NULL",
             name: :workspace_members_workspace_name_index
           )
  end
end
