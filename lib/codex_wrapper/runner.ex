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
  The timeout the runner will actually enforce for a caller's `timeout`.

  Callers pass `nil` for "no timeout", but a runner may substitute a bound
  of its own (`Runner.Forcola` does, since forcola requires a finite one).
  `Command.run/3` uses this to report the timeout that actually elapsed.
  Optional; defaults to the caller's timeout unchanged.
  """
  @callback effective_timeout(timeout :: timeout() | nil) :: timeout() | nil

  @optional_callbacks effective_timeout: 1

  @doc """
  The configured runner module, `CodexWrapper.Runner.Port` by default.

  Set with a module:

      config :codex_wrapper, runner: CodexWrapper.Runner.Forcola

  or with the `:task` / `:forcola` shorthand for the two built-in runners:

      config :codex_wrapper, runner: :forcola

  `:forcola` resolves to `Runner.Port` when the `forcola` dependency is
  absent, so the shorthand is safe to set unconditionally.
  """
  @spec impl() :: module()
  def impl do
    :codex_wrapper
    |> Application.get_env(:runner, CodexWrapper.Runner.Port)
    |> resolve()
  end

  defp resolve(:task), do: CodexWrapper.Runner.Port

  defp resolve(:forcola) do
    if Code.ensure_loaded?(CodexWrapper.Runner.Forcola) do
      CodexWrapper.Runner.Forcola
    else
      CodexWrapper.Runner.Port
    end
  end

  defp resolve(module) when is_atom(module), do: module

  @doc """
  `effective_timeout/1` on `runner`, falling back to `timeout` unchanged
  when the runner does not implement the optional callback.
  """
  @spec effective_timeout(module(), timeout() | nil) :: timeout() | nil
  def effective_timeout(runner, timeout) do
    if function_exported?(runner, :effective_timeout, 1) do
      runner.effective_timeout(timeout)
    else
      timeout
    end
  end
end
