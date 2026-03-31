defmodule CodexWrapper.Commands.McpServer do
  @moduledoc """
  Start Codex as an MCP server over stdio.

  Wraps `codex mcp-server`.

  ## Options

    * `:config` - list of `"key=value"` config overrides (`-c`)
    * `:enable` - list of feature flags to enable (`--enable`)
    * `:disable` - list of feature flags to disable (`--disable`)
  """

  alias CodexWrapper.Config

  @doc """
  Start Codex as an MCP server.

  ## Options

    * `:config` - list of `"key=value"` config overrides
    * `:enable` - list of feature flags to enable
    * `:disable` - list of feature flags to disable

  ## Examples

      config = CodexWrapper.Config.new()
      CodexWrapper.Commands.McpServer.start(config)
      CodexWrapper.Commands.McpServer.start(config, config: ["model=\\"gpt-5\\""], enable: ["web-search"])
  """
  @spec start(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp-server"] ++ build_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp build_args(opts) do
    config_args(opts[:config]) ++ enable_args(opts[:enable]) ++ disable_args(opts[:disable])
  end

  defp config_args(nil), do: []

  defp config_args(overrides) do
    Enum.flat_map(overrides, fn v -> ["-c", v] end)
  end

  defp enable_args(nil), do: []

  defp enable_args(features) do
    Enum.flat_map(features, fn v -> ["--enable", v] end)
  end

  defp disable_args(nil), do: []

  defp disable_args(features) do
    Enum.flat_map(features, fn v -> ["--disable", v] end)
  end
end
