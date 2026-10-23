defmodule CodexWrapper.Commands.Auth do
  @moduledoc """
  Authentication commands -- login, logout, status.

  Wraps `codex login`, `codex logout`, and `codex login status`.

  These commands now use the config's runner instead of `System.cmd`.
  With the default Port runner, execution uses `/bin/sh`, stdin from
  `/dev/null`, and a SIGINT/TERM/KILL watchdog. A missing binary returns
  `{:error, {:exit, 127, output}}` instead of raising.
  Under Forcola, when neither config `:timeout` nor runner option `:timeout_ms`
  is set, the wall bound is the snapshotted `:forcola_default_timeout_ms`
  (300,000 ms unless configured), after which
  the command is cancelled and returns `{:error, {:timeout, milliseconds}}`.
  Set an explicit config `:timeout` long enough for interactive login or
  device authorization under Forcola. The Port runner has no whole-run bound
  unless `:timeout` is set; it does not provide interactive stdin.
  """

  alias CodexWrapper.Config

  @doc """
  Login to Codex.

  ## Options

    * `:with_api_key` - Use API key authentication (boolean)
    * `:with_access_token` - Use access token authentication (boolean)
    * `:device_auth` - Use device authorization flow (boolean)
  """
  @spec login(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def login(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["login"]
    args = if opts[:with_api_key], do: args ++ ["--with-api-key"], else: args
    args = if opts[:with_access_token], do: args ++ ["--with-access-token"], else: args
    args = if opts[:device_auth], do: args ++ ["--device-auth"], else: args

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Logout from Codex.
  """
  @spec logout(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def logout(%Config{} = config) do
    args = Config.base_args(config) ++ ["logout"]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check login status.
  """
  @spec status(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def status(%Config{} = config) do
    args = Config.base_args(config) ++ ["login", "status"]

    case CodexWrapper.Runner.run(config, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, reason} -> {:error, reason}
    end
  end
end
