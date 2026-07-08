defmodule CodexWrapper.Runner do
  @moduledoc """
  How one-shot `codex` subprocesses are executed.

  `Command.run/3` routes every synchronous command (`Exec`, `ExecResume`,
  `Review`, `CodexWrapper.exec/2`) through the configured runner. The
  default is `CodexWrapper.Runner.Port`, the `/bin/sh`-with-closed-stdin
  `Port` the library has always used.

  For leak-free execution -- where a timeout or BEAM death kills the whole
  `codex` process group (the CLI and every stdio MCP server it spawned)
  rather than abandoning it -- add
  [`forcola`](https://hex.pm/packages/forcola) to your deps and select its
  runner:

      # mix.exs
      {:forcola, "~> 0.3"}

      # config/config.exs
      config :codex_wrapper, runner: CodexWrapper.Runner.Forcola

  `Runner.Forcola` only compiles when `forcola` is present, so the
  dependency stays optional. See #48.

  ## Contract

  `run/4` returns `{:ok, {stdout, exit_code}}` on completion (a non-zero
  exit is *not* an error -- callers decide what an exit code means),
  `{:error, :timeout}` when the timeout elapsed, and other `{:error,
  reason}` tuples for spawn/signal/io failures.
  """

  @typedoc "Runner error reasons. `:timeout` is common to every runner."
  @type error ::
          :timeout
          | {:signal, term()}
          | {:spawn, term()}
          | {:io, term()}

  @typedoc """
  Execution options, as produced by `CodexWrapper.Config.cmd_opts/1`:

    * `:cd` -- working directory (string)
    * `:env` -- list of `{name, value}` string tuples
    * `:stderr_to_stdout` -- merge stderr into stdout
  """
  @type opts :: keyword()

  @callback run(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: {:ok, {String.t(), non_neg_integer()}} | {:error, error()}

  @doc """
  The configured runner module, `CodexWrapper.Runner.Port` by default.

  Set with `config :codex_wrapper, runner: CodexWrapper.Runner.Forcola`.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:codex_wrapper, :runner, CodexWrapper.Runner.Port)
  end
end
