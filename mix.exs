defmodule WebRAG.MixProject do
  use Mix.Project

  def project do
    [
      app: :webrag,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Web crawler for building RAG datasets with vector embeddings",
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {WebRAG.Application, []},
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
      {:protobuf, "~> 0.13"}
    ]
  end

  defp package do
    [
      name: :webrag,
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["WebRAG Contributors"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/Aidan-Stokes/webrag"
      }
    ]
  end
end
