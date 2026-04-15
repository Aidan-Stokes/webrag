defmodule Aoncrawler.MixProject do
  use Mix.Project

  def project do
    [
      app: :aoncrawler,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AONCrawler.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core HTTP & Parsing
      {:req, "~> 0.5"},
      {:floki, "~> 0.36"},

      # Database (SQLite + Ecto)
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.12"},
      {:jason, "~> 1.4"},

      # Phoenix for API
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:plug_cowboy, "~> 2.7"},

      # Logging & Observability
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},

      # Utilities
      {:uuid, "~> 1.1"},

      # Testing
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end
end
