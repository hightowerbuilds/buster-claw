defmodule BusterClaw.MixProject do
  use Mix.Project

  # Single source of truth for the app version. The Tauri config and the Rust
  # crate are kept in sync from this same file by scripts/sync_version.sh, so a
  # release only ever requires editing VERSION.
  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()

  def project do
    [
      app: :buster_claw,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      escript: escript(),
      dialyzer: dialyzer()
    ]
  end

  defp dialyzer do
    [
      # Outside priv/ on purpose: everything in priv/ ships inside the release,
      # and these are build-time caches (they were ~10% of the DMG).
      plt_local_path: "_plts",
      plt_core_path: "_plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :unmatched_returns, :unknown]
    ]
  end

  defp escript do
    [
      main_module: BusterClaw.CLI,
      name: "buster-claw",
      path: "buster-claw",
      app: nil
    ]
  end

  defp releases do
    [
      buster_claw: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BusterClaw.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind buster_claw", "esbuild buster_claw"],
      "assets.deploy": [
        "compile",
        "tailwind buster_claw --minify",
        "esbuild buster_claw --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ],
      # GHSA-52mm-h59v-f3c7 (earmark stored-XSS via HTML attribute) has no
      # upstream patch; rendered markdown is run through html_sanitize_ex, which
      # mitigates it. Revisit if earmark ships a fix or the render path changes.
      lint: [
        "credo --strict",
        "sobelow --config",
        "deps.audit --ignore-advisory-ids GHSA-52mm-h59v-f3c7",
        "cmd scripts/check_docs_drift.sh"
      ]
    ]
  end
end
