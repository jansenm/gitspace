defmodule Gitspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :gitspace,
      version: "0.5.3",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Gitspace.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      gitspace: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            # Burrito treats every Linux target as a cross-build and rebuilds
            # NIF deps with `zig cc ... -shared`. Exile also ships an executable
            # helper (`spawner`), which cannot be linked with -shared. Since we
            # build natively, use the host-compiled NIFs unchanged.
            linux_x86_64: [
              os: :linux,
              cpu: :x86_64,
              skip_nifs: true,
              # Use the host OTP (glibc) instead of Burrito's musl ERTS:
              # SQLite's NIF is compiled against glibc and cannot load in musl.
              custom_erts:
                System.get_env("GITSPACE_ERTS") ||
                  Path.join(to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}")
            ]
          ]
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => "https://github.com/jansenm/gitspace"}
    ]
  end

  defp deps do
    [
      {:exile, "~> 0.15"},
      {:jason, "~> 1.4"},
      {:ecto_sqlite3, "~> 0.26"},
      {:toml_elixir, "~> 3.3"},
      {:burrito, "~> 1.5.0"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
