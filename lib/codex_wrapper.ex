defmodule CodexWrapper do
  @moduledoc """
  Elixir wrapper for the Codex CLI.

  Provides a typed interface for executing commands against the `codex` CLI.

  ## Quick start

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

  ## Binary discovery

  The `codex` binary is found via (in order):
  1. `:binary` option passed directly
  2. `CODEX_CLI` environment variable
  3. System PATH lookup
  """

  alias CodexWrapper.Config

  @doc """
  Run an arbitrary CLI command that isn't wrapped by a dedicated module.

  This is the escape hatch for new or experimental CLI subcommands.

  ## Examples

      CodexWrapper.raw(["version"])
      CodexWrapper.raw(["exec", "fix the tests"], working_dir: "/tmp")
  """
  @spec raw([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def raw(args, opts \\ []) when is_list(args) do
    config = Config.new(opts)
    all_args = Config.base_args(config) ++ args
    cmd_opts = Config.cmd_opts(config)

    case System.cmd(config.binary, all_args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd, e}}
  end
end
