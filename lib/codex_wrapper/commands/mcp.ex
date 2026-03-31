defmodule CodexWrapper.Commands.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server management commands.

  Wraps `codex mcp list|get|add|remove`.
  """

  alias CodexWrapper.Config

  @doc """
  List configured MCP servers.

  ## Options

    * `:json` - Return JSON output (boolean)
  """
  @spec list(Config.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "list"]
    args = if opts[:json], do: args ++ ["--json"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        if opts[:json] do
          case Jason.decode(output) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {:error, {:json_decode, reason}}
          end
        else
          {:ok, String.trim(output)}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Get details for a specific MCP server.

  ## Options

    * `:json` - Return JSON output (boolean)
  """
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "get", name]
    args = if opts[:json], do: args ++ ["--json"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        if opts[:json] do
          case Jason.decode(output) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {:error, {:json_decode, reason}}
          end
        else
          {:ok, String.trim(output)}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Add an MCP server.

  ## Stdio transport

      Mcp.add(config, "my-server", :stdio, command: "npx", args: ["-y", "server"], env: %{"KEY" => "val"})

  ## HTTP transport

      Mcp.add(config, "my-server", :http, url: "http://localhost:8080")
  """
  @spec add(Config.t(), String.t(), :stdio | :http, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, name, :stdio, opts) do
    command = Keyword.fetch!(opts, :command)
    command_args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})

    args = Config.base_args(config) ++ ["mcp", "add", name]
    args = args ++ env_args(env)
    args = args ++ ["--", command] ++ command_args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  def add(%Config{} = config, name, :http, opts) do
    url = Keyword.fetch!(opts, :url)

    args = Config.base_args(config) ++ ["mcp", "add", name, "--url", url]

    args =
      case Keyword.get(opts, :bearer_token_env_var) do
        nil -> args
        var -> args ++ ["--bearer-token-env-var", var]
      end

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Remove an MCP server.
  """
  @spec remove(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def remove(%Config{} = config, name) do
    args = Config.base_args(config) ++ ["mcp", "remove", name]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp env_args(env) when map_size(env) == 0, do: []

  defp env_args(env) do
    Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)
  end
end
