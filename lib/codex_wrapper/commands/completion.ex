defmodule CodexWrapper.Commands.Completion do
  @moduledoc """
  Shell completion script generation.

  Wraps `codex completion [SHELL]` to generate shell-specific completion scripts.
  """

  alias CodexWrapper.Config

  @type shell :: :bash | :zsh | :fish | :elvish | :powershell

  @shells [:bash, :zsh, :fish, :elvish, :powershell]

  @doc """
  Generate a shell completion script.

  ## Examples

      config = CodexWrapper.Config.new()
      {:ok, script} = CodexWrapper.Commands.Completion.generate(config)
      {:ok, script} = CodexWrapper.Commands.Completion.generate(config, :zsh)
  """
  @spec generate(Config.t(), shell()) :: {:ok, String.t()} | {:error, term()}
  def generate(%Config{} = config, shell \\ :bash) when shell in @shells do
    args = Config.base_args(config) ++ ["completion", Atom.to_string(shell)]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end
end
