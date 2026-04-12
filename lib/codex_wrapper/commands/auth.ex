defmodule CodexWrapper.Commands.Auth do
  @moduledoc """
  Authentication commands -- login, logout, status.

  Wraps `codex login`, `codex logout`, and `codex login status`.
  """

  alias CodexWrapper.Config

  @doc """
  Login to Codex.

  ## Options

    * `:with_api_key` - Use API key authentication (boolean)
    * `:device_auth` - Use device authorization flow (boolean)
  """
  @spec login(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def login(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["login"]
    args = if opts[:with_api_key], do: args ++ ["--with-api-key"], else: args
    args = if opts[:device_auth], do: args ++ ["--device-auth"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Logout from Codex.
  """
  @spec logout(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def logout(%Config{} = config) do
    args = Config.base_args(config) ++ ["logout"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Check login status.
  """
  @spec status(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def status(%Config{} = config) do
    args = Config.base_args(config) ++ ["login", "status"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end
end
