defmodule CodexWrapper.Commands.Version do
  @moduledoc """
  Version command — parse `codex --version` output.
  """

  alias CodexWrapper.Config

  @doc """
  Get the Codex CLI version.

  Returns the trimmed version string from `codex --version`.
  """
  @spec execute(Config.t()) :: {:ok, %{version: String.t(), raw: String.t()}} | {:error, term()}
  def execute(%Config{} = config) do
    args = Config.base_args(config) ++ ["--version"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        raw = String.trim(output)
        {:ok, %{version: raw, raw: raw}}

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end
end
