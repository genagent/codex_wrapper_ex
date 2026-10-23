defmodule CodexWrapper.Commands.Version do
  @moduledoc """
  Version command -- parse `codex --version` output.
  """

  alias CodexWrapper.Config

  @doc """
  Get the Codex CLI version.

  Returns the trimmed version string from `codex --version`.
  """
  @spec execute(Config.t()) :: {:ok, %{version: String.t(), raw: String.t()}} | {:error, term()}
  def execute(%Config{} = config) do
    args = Config.base_args(config) ++ ["--version"]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} ->
        raw = String.trim(output)
        {:ok, %{version: raw, raw: raw}}

      {:ok, {output, code}} ->
        {:error, {:exit, code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
