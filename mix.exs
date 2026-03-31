defmodule CodexWrapperEx.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/joshrotenberg/codex_wrapper_ex"

  def project do
    [
      app: :codex_wrapper,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "CodexWrapper",
      description: "Elixir wrapper for the Codex CLI"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "CodexWrapper",
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
