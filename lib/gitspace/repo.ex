defmodule Gitspace.Repo do
  @moduledoc "SQLite index. Disposable: `doctor --reindex` rebuilds it from git and markers."

  use Ecto.Repo, otp_app: :gitspace, adapter: Ecto.Adapters.SQLite3
end
