if Code.ensure_loaded?(Forcola) do
  defmodule CodexWrapper.Runner.Forcola do
    @moduledoc """
    Leak-free runner backed by [forcola](https://hex.pm/packages/forcola).

    Every `codex` invocation runs under forcola's Rust shim, which places
    the CLI in its own process group and kills the whole group (SIGTERM,
    then SIGKILL) on timeout or when the BEAM dies. That reaps `codex` and
    every stdio MCP server it spawned together, where the default
    `CodexWrapper.Runner.Port` would leave them running as orphans (see
    #48 and closed #33).

    forcola closes the child's stdin immediately after spawn (forcola
    0.3.4, forcola#67), so `codex` sees EOF naturally -- the `/bin/sh
    ... < /dev/null` wrapper the default runner needs is unnecessary
    here. Before 0.3.4 forcola left the child's stdin open, and `codex
    exec` would print "Reading additional input from stdin..." and hang
    until the timeout elapsed. The `~> 0.6.0` dependency floor includes
    this fix and raw output observation for one-shot execution.

    forcola requires a finite whole-run bound. Synchronous commands with
    no `:timeout` use `forcola_default_timeout_ms` (five minutes by
    default); streams use `forcola_default_stream_timeout_ms` (one hour
    by default), so a long active turn is not cut off after five minutes.

    `stream_lines/4` is backed by `Forcola.Stream.lines/2`, so the
    NDJSON paths (`Exec.stream/2` and friends) get the same group kill
    on halt, timeout, or BEAM death. Unlike `Forcola.Stream.lines/2`,
    it does not raise on a non-zero exit -- it ends the stream, which is
    what `CodexWrapper.Runner.Port` has always done and what the
    `CodexWrapper.Runner` contract specifies.

    This module compiles only when `forcola` is a dependency. Select it
    with `config :codex_wrapper, runner: CodexWrapper.Runner.Forcola`
    (or the `:forcola` shorthand). forcola is POSIX-only.
    """

    @behaviour CodexWrapper.Runner

    # forcola requires a mandatory whole-run bound. When the caller sets no
    # timeout we still want group-kill-on-BEAM-death, so we substitute a
    # configurable default rather than falling back to the leaky path.
    @default_timeout_ms 300_000
    @default_stream_timeout_ms 3_600_000

    @doc """
    The bound forcola will enforce for `timeout`.

    A caller's `nil` ("no timeout") becomes
    `config :codex_wrapper, forcola_default_timeout_ms: <ms>`
    (default `#{@default_timeout_ms}`), since forcola requires a finite bound.
    """
    @impl true
    def effective_timeout(nil) do
      Application.get_env(:codex_wrapper, :forcola_default_timeout_ms, @default_timeout_ms)
    end

    def effective_timeout(timeout), do: timeout

    defp stream_timeout(nil) do
      Application.get_env(
        :codex_wrapper,
        :forcola_default_stream_timeout_ms,
        Application.get_env(
          :codex_wrapper,
          :forcola_default_timeout_ms,
          @default_stream_timeout_ms
        )
      )
    end

    defp stream_timeout(timeout), do: timeout

    @impl true
    def run(binary, args, opts, timeout) do
      forcola_opts =
        [timeout_ms: effective_timeout(timeout), merge_stderr: merge_stderr?(opts)] ++
          Keyword.take(opts, [:cd, :env])

      case Forcola.run([binary | args], forcola_opts) do
        {:ok, %Forcola.Result{status: status, stdout: stdout}} when is_integer(status) ->
          {:ok, {stdout, status}}

        {:ok, %Forcola.Result{status: {:signal, signal}}} ->
          {:error, {:signal, signal}}

        {:error, {:timeout, _partial}} ->
          {:error, :timeout}

        {:error, {:spawn, reason}} ->
          {:error, {:spawn, reason}}
      end
    end

    @doc """
    Observe raw output while preserving the terminal one-shot outcome.

    Requires Forcola's `:output_observer` support. The execution caller
    receives raw chunks from its owned helper before this function returns.
    Stderr stays separate.
    """
    @spec run_observed(String.t(), [String.t()], keyword(), timeout() | nil, {pid(), reference()}) ::
            {:ok, {binary(), non_neg_integer(), binary()}}
            | {:error, CodexWrapper.Runner.error()}
    @impl true
    def run_observed(binary, args, opts, timeout, target) do
      forcola_opts =
        [timeout_ms: effective_timeout(timeout), merge_stderr: false, output_observer: target] ++
          Keyword.take(opts, [:cd, :env])

      case Forcola.run([binary | args], forcola_opts) do
        {:ok, %Forcola.Result{status: status, stdout: stdout, stderr: stderr}}
        when is_integer(status) ->
          {:ok, {stdout, status, stderr}}

        {:ok, %Forcola.Result{status: {:signal, signal}}} ->
          {:error, {:signal, signal}}

        {:error, {:timeout, _partial}} ->
          {:error, :timeout}

        {:error, {:spawn, reason}} ->
          {:error, {:spawn, reason}}
      end
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, 300_000)
      timeout = stream_timeout(timeout)

      stream_opts =
        [timeout_ms: timeout, merge_stderr: merge_stderr?(opts)] ++
          Keyword.take(opts, [:cd, :env])

      stream_opts =
        if idle_timeout_ms,
          do: Keyword.put(stream_opts, :idle_timeout_ms, idle_timeout_ms),
          else: stream_opts

      [binary | args]
      |> Forcola.Stream.lines(stream_opts)
      |> halt_on_error(timeout, idle_timeout_ms)
    end

    # `Forcola.Stream.lines/2` raises on a non-zero exit, a signal, a
    # timeout, or a spawn failure. The wrapper's streaming contract ends
    # the stream instead (see `CodexWrapper.Runner`), so translate.
    # forcola has already killed the process group by the time it raises,
    # so there is nothing left to clean up.
    defp halt_on_error(enum, timeout, idle_timeout_ms) do
      Stream.resource(
        fn -> &Enumerable.reduce(enum, &1, fn line, _acc -> {:suspend, line} end) end,
        &pull(&1, timeout, idle_timeout_ms),
        fn
          :done -> :ok
          cont -> halt_continuation(cont)
        end
      )
    end

    defp pull(:done, _timeout, _idle_timeout_ms), do: {:halt, :done}

    defp pull(cont, timeout, idle_timeout_ms) do
      case cont.({:cont, nil}) do
        {:suspended, line, next} -> {[line], next}
        {:done, _acc} -> {:halt, :done}
        {:halted, _acc} -> {:halt, :done}
      end
    rescue
      error in Forcola.Stream.Error ->
        cond do
          error.idle_timed_out -> {[{:error, {:idle_timeout, idle_timeout_ms}}], :done}
          error.timed_out -> {[{:error, {:timeout, timeout}}], :done}
          true -> {:halt, :done}
        end
    end

    # Halting the suspended reduction is what kills the process group on an
    # early `Enum.take/2`. It runs forcola's own cleanup, which raises for
    # the same reasons `pull/1` guards against.
    defp halt_continuation(cont) do
      cont.({:halt, nil})
      :ok
    rescue
      Forcola.Stream.Error -> :ok
    end

    defp merge_stderr?(opts), do: Keyword.get(opts, :stderr_to_stdout, false)
  end
end
