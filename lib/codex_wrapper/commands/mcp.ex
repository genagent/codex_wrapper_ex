defmodule CodexWrapper.Commands.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server management commands.

  Wraps `codex mcp list|get|add|remove|login|logout`.
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
      {output, 0} -> parse_output(output, opts[:json])
      {output, code} -> {:error, {:exit, code, output}}
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
      {output, 0} -> parse_output(output, opts[:json])
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Add an MCP server.

  ## Stdio transport

      Mcp.add(config, "my-server", :stdio, command: "npx", args: ["-y", "server"], env: %{"KEY" => "val"})

  ## HTTP transport

      Mcp.add(config, "my-server", :http, url: "http://localhost:8080")

  ## OAuth

  `:oauth_client_id` and `:oauth_resource` are accepted on both transports;
  the CLI does not restrict them to one. They configure the OAuth exchange
  that `login/3` later performs.

      Mcp.add(config, "remote", :http,
        url: "https://example.com/mcp",
        oauth_client_id: "codex-cli",
        oauth_resource: "https://example.com"
      )

  ## Options

    * `:oauth_client_id` - OAuth client identifier for this server
    * `:oauth_resource` - OAuth resource parameter to include during login
  """
  @spec add(Config.t(), String.t(), :stdio | :http, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, name, :stdio, opts) do
    command = Keyword.fetch!(opts, :command)
    command_args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})

    args = Config.base_args(config) ++ ["mcp", "add", name]
    args = args ++ env_args(env) ++ oauth_args(opts)
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

    args = args ++ oauth_args(opts)

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

  @doc """
  Authenticate with an MCP server over OAuth.

      Mcp.login(config, "remote")
      Mcp.login(config, "remote", scopes: ["read", "write"])

  ## Options

    * `:scopes` - OAuth scopes to request, as a list or an already-joined
      comma-separated string
  """
  @spec login(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def login(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "login", name] ++ scopes_args(opts[:scopes])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Deauthenticate an MCP server.
  """
  @spec logout(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def logout(%Config{} = config, name) do
    args = Config.base_args(config) ++ ["mcp", "logout", name]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp parse_output(output, true) do
    case Jason.decode(output) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  defp parse_output(output, _), do: {:ok, String.trim(output)}

  defp env_args(env) when map_size(env) == 0, do: []

  defp env_args(env) do
    Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)
  end

  defp oauth_args(opts) do
    [{:oauth_client_id, "--oauth-client-id"}, {:oauth_resource, "--oauth-resource"}]
    |> Enum.flat_map(fn {key, flag} ->
      case Keyword.get(opts, key) do
        nil -> []
        value -> [flag, value]
      end
    end)
  end

  defp scopes_args(nil), do: []
  defp scopes_args(scopes) when is_list(scopes), do: ["--scopes", Enum.join(scopes, ",")]
  defp scopes_args(scopes) when is_binary(scopes), do: ["--scopes", scopes]
end
