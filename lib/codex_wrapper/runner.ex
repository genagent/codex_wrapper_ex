defmodule CodexWrapper.Runner do
  require Logger

  @moduledoc """
  How one-shot `codex` subprocesses are executed.

  `Command.run/3` routes every synchronous command (`Exec`, `ExecResume`,
  `Review`, `CodexWrapper.exec/2`) through the configured runner. The
  default is `CodexWrapper.Runner.Port`, the `/bin/sh`-with-closed-stdin
  `Port` the library has always used.

  When its port closes (a timeout, an early stream halt, the owning
  process dying, or the BEAM dying) the default runner signals the `codex`
  process: SIGINT, so a cooperating `codex` can stop its tool children,
  then SIGTERM and SIGKILL if it stays alive. It does not signal the
  process group, so processes `codex` does not stop itself can survive; see
  `CodexWrapper.Runner.Port` for the exact behavior and limits.

  To kill the whole `codex` process group on a timeout or BEAM death (the
  CLI and every stdio MCP server it spawned), add
  [`forcola`](https://hex.pm/packages/forcola) to your deps and select its
  runner:

      # mix.exs
      {:forcola, "~> 0.7.0"}

      # config/config.exs
      config :codex_wrapper, runner: CodexWrapper.Runner.Forcola

  `Runner.Forcola` only compiles when `forcola` is present, so the
  dependency stays optional. See #48.

  ## Contract

  `run/4` returns `{:ok, {stdout, exit_code}}` on completion (a non-zero
  exit is *not* an error -- callers decide what an exit code means),
  `{:error, :timeout}` when the timeout elapsed, and other `{:error,
  reason}` tuples for spawn/signal/io failures.

  `stream_lines/4` returns a lazy `Enumerable` of stdout lines for the
  NDJSON paths (`Exec.stream/2`, `ExecResume.stream/2`, `Review.stream/2`,
  and `Session.stream/3` through the first two). Lines arrive without
  their trailing newline, stderr is never merged into them, and the
  stream ends when the process exits. A deadline emits a final
  `{:error, {:timeout, ms}}` or `{:error, {:idle_timeout, ms}}` item.

  A run that ends badly emits a final error item after its last line,
  without raising: `{:error, {:exit_status, code}}` for a nonzero exit,
  `{:error, {:spawn, reason}}` when the process could not be started, and
  `{:error, {:signal, signal}}` when `Runner.Forcola` reports death by
  signal. On `Runner.Port` a missing executable is exit status 127 from
  the shell. A zero exit ends the stream with no error item.
  """

  @typedoc "Runner error reasons. `:timeout` is common to every runner."
  @type error ::
          :timeout
          | :idle_timeout
          | :max_output_bytes
          | :observer_overflow
          | {:exit_status, pos_integer()}
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
  Run `binary` with `args` and stream its stdout as lines.

  Returns a lazy `Enumerable` of lines without their trailing newlines.
  Opening the process is deferred until the stream is consumed, and the
  process is signalled for termination when the stream halts (including an
  early `Enum.take/2`); `Runner.Port` and `Runner.Forcola` differ in how
  far that reaches.

  `timeout` bounds the whole run. The independent
  `opts[:idle_timeout_ms]` bounds gaps between output frames; `nil`
  disables the idle bound. When `timeout` is `nil`, `Runner.Port` has no
  whole-run bound and `Runner.Forcola` uses its configurable default.
  Both built-in runners default to a 300,000 ms idle bound.

  Optional. `CodexWrapper.Runner.stream_lines/4` warns and falls back to
  `Runner.Port` for runners that do not implement it.
  """
  @callback stream_lines(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: Enumerable.t()

  @doc """
  The timeout the runner will actually enforce for a caller's `timeout`.

  Callers pass `nil` for "no timeout", but a runner may substitute a bound
  of its own (`Runner.Forcola` does, since forcola requires a finite one).
  `Command.run/3` uses this to report the timeout that actually elapsed.
  Optional; defaults to the caller's timeout unchanged.
  """
  @callback effective_timeout(timeout :: timeout() | nil) :: timeout() | nil

  @doc """
  Optional observed one-shot transport. Send raw stdout/stderr chunks as
  `{reference, {:stdout | :stderr, bytes}}` to the given target directly from
  the process calling this function, before returning its terminal outcome.
  Preserve all bytes and keep stderr separate regardless of legacy opts.
  `CodexWrapper.ObservedExecution` owns the calling helper and forwards typed
  identity from the execution caller. No runner fallback is allowed.
  """
  @callback run_observed(String.t(), [String.t()], opts(), timeout() | nil, {pid(), reference()}) ::
              {:ok, {binary(), non_neg_integer(), binary()}} | {:error, error()}

  @doc """
  Optional evidenced one-shot transport. Uses the same raw chunk observer as
  `run_observed/5`. Returns `{legacy_outcome, evidence_map}`; missing facts
  remain unknown. Evidence keys are documented in `CodexWrapper.ExecutionObservation`.
  The evidence map carries `:stdout` / `:stderr` bounded prefixes plus native
  `:child_status`, `:child_signal`, `:termination`, `:reason`,
  `:output_truncated`, `:cleanup`, `:scope`, and `:guard_close` when known.
  No raw child exit may be synthesized for a pre-spawn failure. Notifications
  must come from the calling process before return, preserving message order.
  `timeout` is a finite positive wall bound computed from the config. Forcola
  uses the snapshotted `:forcola_default_timeout_ms` (300,000 ms unless configured)
  when no explicit limit is set; other runners default to 300,000 ms. Idle and
  combined output defaults are 300,000 ms and 1 MiB. `:idle_timeout_ms` and
  `:max_output_bytes` are included in opts.
  Implementations must bound output and execution, preserve partial output on
  failure, and finish native cleanup before returning. No fallback is allowed.
  """
  @callback run_evidenced(String.t(), [String.t()], opts(), pos_integer(), {pid(), reference()}) ::
              {term(), map()}

  @doc "Validate supported per-config requirements before any subprocess is opened."
  @callback validate_options(keyword()) :: :ok | {:error, term()}

  @doc "Optional capability preflight, checked before invoking run_evidenced/5."
  @callback validate_evidence() :: :ok | {:error, term()}

  @optional_callbacks validate_evidence: 0,
                      effective_timeout: 1,
                      stream_lines: 4,
                      run_observed: 5,
                      run_evidenced: 5,
                      validate_options: 1

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

  def resolve(:task), do: CodexWrapper.Runner.Port

  def resolve(:forcola) do
    if Code.ensure_loaded?(CodexWrapper.Runner.Forcola) do
      CodexWrapper.Runner.Forcola
    else
      CodexWrapper.Runner.Port
    end
  end

  def resolve(module) when is_atom(module) and not is_nil(module), do: module
  def resolve(value), do: raise(ArgumentError, "invalid runner: #{inspect(value)}")

  @doc "Resolve the runner selected by a config."
  @spec impl(CodexWrapper.Config.t()) :: module()
  def impl(%{runner: nil}), do: impl()
  def impl(%{runner: runner}), do: resolve(runner)

  @doc false
  def validate_options(runner, options) do
    Code.ensure_loaded(runner)

    cond do
      options == [] -> :ok
      function_exported?(runner, :validate_options, 1) -> runner.validate_options(options)
      true -> {:error, {:runner_options_unsupported, runner}}
    end
  end

  @doc false
  def run(config, args) do
    runner = impl(config)

    with :ok <- validate_options(runner, CodexWrapper.Config.runner_options(config)) do
      case runner.run(
             config.binary,
             args,
             CodexWrapper.Config.execution_opts(config),
             timeout(config)
           ) do
        {:error, :timeout} ->
          bound = effective_timeout(runner, timeout(config))
          {:error, {:timeout, bound}}

        outcome ->
          outcome
      end
    end
  end

  @doc false
  def timeout(config) do
    if impl(config) == CodexWrapper.Runner.Forcola do
      config.timeout || CodexWrapper.Config.runner_options(config)[:timeout_ms] ||
        config.runner_default_timeout_ms || effective_timeout(impl(config), nil)
    else
      config.timeout
    end
  end

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

  @doc """
  `stream_lines/4` on the configured runner.

  Falls back to `CodexWrapper.Runner.Port` with a warning when the
  configured runner cannot be loaded or does not implement the optional
  callback, so a runner written against the one-shot `run/4` contract
  alone keeps working. A configured runner is loaded before checking the
  callback.
  """
  @spec stream_lines(String.t(), [String.t()], opts(), timeout() | nil) :: Enumerable.t()
  def stream_lines(binary, args, opts, timeout) do
    stream_lines(impl(), binary, args, opts, timeout)
  end

  @doc false
  def stream_lines(%CodexWrapper.Config{} = config, binary, args, opts, timeout) do
    runner = impl(config)

    if config.runner_explicit != false and not is_nil(config.runner) do
      unless Code.ensure_loaded?(runner) and function_exported?(runner, :stream_lines, 4),
        do:
          raise(
            ArgumentError,
            "explicit runner #{inspect(runner)} does not implement stream_lines/4"
          )

      runner.stream_lines(binary, args, opts, timeout)
    else
      stream_lines(runner, binary, args, opts, timeout)
    end
  end

  def stream_lines(runner, binary, args, opts, timeout) do
    runner =
      case Code.ensure_loaded(runner) do
        {:module, ^runner} ->
          if function_exported?(runner, :stream_lines, 4) do
            runner
          else
            Logger.warning(
              "configured CodexWrapper runner #{inspect(runner)} does not implement stream_lines/4; falling back to CodexWrapper.Runner.Port"
            )

            CodexWrapper.Runner.Port
          end

        {:error, reason} ->
          Logger.warning(
            "configured CodexWrapper runner #{inspect(runner)} could not be loaded (#{inspect(reason)}); falling back to CodexWrapper.Runner.Port"
          )

          CodexWrapper.Runner.Port
      end

    runner.stream_lines(binary, args, opts, timeout)
  end
end
