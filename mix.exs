defmodule TamaMCP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kritama/tama-mcp"

  def project do
    [
      app: :tama_mcp,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp description do
    "Tama-focused MCP 2026-07-28 server primitives for Elixir applications."
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_add_apps: [:ex_unit, :mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jsonschex, "~> 0.3.0"},
      {:plug, "~> 1.18"},
      {:tama_oauth, "~> 0.4.1"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
