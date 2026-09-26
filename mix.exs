defmodule CodexWrapperEx.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/genagent/codex_wrapper_ex"

  def project do
    [
      app: :codex_wrapper,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"},
        # `mix codex.contract` is a Mix task, so Mix must be in the PLT.
        plt_add_apps: [:mix]
      ],
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
      {:telemetry, "~> 1.0"},
      {:forcola, "~> 0.3", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "CodexWrapper",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        "Running codex": [
          CodexWrapper,
          CodexWrapper.Exec,
          CodexWrapper.ExecResume,
          CodexWrapper.ExecFork,
          CodexWrapper.Review,
          CodexWrapper.Session,
          CodexWrapper.SessionServer,
          CodexWrapper.IEx
        ],
        "Config, results, support": [
          CodexWrapper.Config,
          CodexWrapper.Result,
          CodexWrapper.JsonLineEvent,
          CodexWrapper.Retry,
          CodexWrapper.Telemetry,
          CodexWrapper.Telemetry.Stream,
          CodexWrapper.UnsupportedError
        ],
        "Subprocess execution": [
          CodexWrapper.Runner,
          CodexWrapper.Runner.Port,
          CodexWrapper.Runner.Forcola
        ],
        "Command surface": [
          CodexWrapper.Command,
          CodexWrapper.Commands.Apply,
          CodexWrapper.Commands.Archive,
          CodexWrapper.Commands.Auth,
          CodexWrapper.Commands.Completion,
          CodexWrapper.Commands.Doctor,
          CodexWrapper.Commands.Features,
          CodexWrapper.Commands.Mcp,
          CodexWrapper.Commands.McpServer,
          CodexWrapper.Commands.Sandbox,
          CodexWrapper.Commands.Version
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
