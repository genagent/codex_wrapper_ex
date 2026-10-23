if Code.ensure_loaded?(Forcola) do
  defmodule CodexWrapper.Runner.Forcola do
    @moduledoc """
    Process-group runner backed by [forcola](https://hex.pm/packages/forcola).

    Evidenced one-shot execution requires Forcola 0.7's reviewed PR #97 run/2
    contract and matching shim. Forcola 0.6 cannot establish these facts and is
    rejected before invoking `run_evidenced/5`. Legacy run/stream callbacks
    remain available.
    New options pass through without global environment or application changes.
    Native exit, cancellation reason, transport, cleanup confirmation/scope and
    guard close are retained independently. Missing evidence remains unknown.
    A confirmed process group never proves containment of escaped descendants.

    Every `codex` invocation runs under forcola's Rust shim, which places
    the CLI in its own process group and kills the whole group (SIGTERM,
    then SIGKILL) on timeout or when the BEAM dies. That reaps `codex` and
    every stdio MCP server it spawned together. The default
    `CodexWrapper.Runner.Port` signals only the `codex` process (SIGINT,
    SIGTERM, SIGKILL), so anything `codex` does not stop itself can outlive
    it (see #48 and closed #33).

    forcola closes the child's stdin immediately after spawn (forcola
    0.3.4, forcola#67), so `codex` sees EOF naturally -- the `/bin/sh
    ... < /dev/null` wrapper the default runner needs is unnecessary
    here. Before 0.3.4 forcola left the child's stdin open, and `codex
    exec` would print "Reading additional input from stdin..." and hang
    until the timeout elapsed. The `~> 0.7.0` dependency floor includes
    this fix, raw output observation and bounded one-shot termination evidence.

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
    @transport_options [
      :shim_path,
      :env_mode,
      :timeout_ms,
      :idle_timeout_ms,
      :max_output_bytes,
      :kill_grace_ms,
      :interrupt_signal,
      :interrupt_grace_ms
    ]

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

    @doc false
    @impl true
    def validate_options(options) do
      CodexWrapper.Config.validate_runner_options!(options)

      if Keyword.keys(options) -- [:timeout_ms, :kill_grace_ms, :shim_path] == [] or
           (Code.ensure_loaded?(Forcola.Run) and Map.has_key?(struct(Forcola.Result), :evidence)),
         do: :ok,
         else: {:error, {:forcola_contract_unavailable, :run_evidence}}
    end

    @impl true
    def run(binary, args, opts, timeout) do
      with :ok <- validate_options(Keyword.take(opts, @transport_options)) do
        Forcola.run([binary | args], one_shot_opts(opts, timeout))
        |> project(
          timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end),
          false
        )
      end
    end

    @impl true
    def run_observed(binary, args, opts, timeout, target) do
      with :ok <- validate_options(Keyword.take(opts, @transport_options)) do
        forcola_opts =
          one_shot_opts(opts, timeout)
          |> Keyword.put(:merge_stderr, false)
          |> Keyword.put(:output_observer, target)

        Forcola.run([binary | args], forcola_opts)
        |> project(
          timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end),
          true
        )
      end
    end

    @impl true
    def validate_evidence do
      validate_options(max_output_bytes: 1_048_576)
    end

    @impl true
    def run_evidenced(binary, args, opts, timeout, target) do
      # A 0.6 collector cannot prove the new contract. Refuse before Forcola.run
      # or shim discovery; an unresolved 0.6 dependency must not silently run it.
      case validate_evidence() do
        :ok ->
          bound = timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)

          forcola_opts =
            one_shot_opts(opts, timeout)
            |> Keyword.put(:merge_stderr, false)
            |> Keyword.put(:output_observer, target)
            |> Keyword.put_new(:idle_timeout_ms, @default_timeout_ms)
            |> Keyword.put_new(:max_output_bytes, 1_048_576)

          outcome = Forcola.run([binary | args], forcola_opts)
          {project(outcome, bound, true), evidence(outcome)}

        {:error, _} = error ->
          {error, %{termination: :pre_spawn}}
      end
    end

    defp one_shot_opts(opts, timeout) do
      Keyword.take(opts, [
        :cd,
        :env,
        :shim_path,
        :env_mode,
        :idle_timeout_ms,
        :max_output_bytes,
        :interrupt_signal,
        :interrupt_grace_ms,
        :kill_grace_ms
      ])
      |> Keyword.put(
        :timeout_ms,
        timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)
      )
      |> Keyword.put(:merge_stderr, merge_stderr?(opts))
    end

    defp project(
           {:ok, %Forcola.Result{status: status, stdout: stdout, stderr: stderr}},
           _,
           observed
         )
         when is_integer(status) do
      if observed, do: {:ok, {stdout, status, stderr}}, else: {:ok, {stdout, status}}
    end

    defp project({:ok, %Forcola.Result{status: {:signal, signal}}}, _, _),
      do: {:error, {:signal, signal}}

    defp project({:error, {:timeout, _partial}}, _timeout, false), do: {:error, :timeout}
    defp project({:error, {:timeout, _partial}}, timeout, true), do: {:error, {:timeout, timeout}}

    defp project({:error, {reason, _partial}}, _, _)
         when reason in [:idle_timeout, :max_output_bytes, :observer_overflow],
         do: {:error, reason}

    defp project({:error, {:spawn, reason}}, _, _), do: {:error, {:spawn, reason}}

    defp evidence({:ok, %Forcola.Result{} = result}), do: result_evidence(result)
    defp evidence({:error, {_, %Forcola.Result{} = result}}), do: result_evidence(result)

    defp evidence({:error, {:spawn, {_, %Forcola.Result{} = result}}}),
      do: result_evidence(result)

    defp evidence({:error, {:spawn, reason}}), do: %{termination: {:spawn, reason}}

    defp result_evidence(result) do
      Map.merge(Map.get(result, :evidence) || %{}, %{stdout: result.stdout, stderr: result.stderr})
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
