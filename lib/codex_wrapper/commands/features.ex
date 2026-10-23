defmodule CodexWrapper.Commands.Features do
  @moduledoc """
  Feature flag management commands.

  Wraps `codex features list|enable|disable`.
  """

  alias CodexWrapper.Config

  @doc """
  List available features.
  """
  @spec list(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def list(%Config{} = config) do
    args = Config.base_args(config) ++ ["features", "list"]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enable a feature.
  """
  @spec enable(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def enable(%Config{} = config, feature) do
    args = Config.base_args(config) ++ ["features", "enable", feature]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Disable a feature.
  """
  @spec disable(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def disable(%Config{} = config, feature) do
    args = Config.base_args(config) ++ ["features", "disable", feature]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end
end
