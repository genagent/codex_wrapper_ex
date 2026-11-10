if Code.ensure_loaded?(Forcola) do
  defmodule CodexWrapper.Runner.Forcola do
    @moduledoc """
    Process-group runner backed by [forcola](https://hex.pm/packages/forcola).

    Requires Forcola `~> 0.12` and its matching shim. Evidenced one-shot
    execution needs the `run/2` evidence contract; a Forcola without it is
    rejected before invoking `run_evidenced/5`.
    New options pass through without global environment or application changes.
    Native exit, cancellation reason, transport, cleanup confirmation/scope and
    guard close are retained independently. Missing evidence remains unknown.
    A confirmed process group never proves containment of escaped descendants.

    Every `codex` invocation runs under forcola's Rust shim, which places
    the CLI in its own process group and signals the whole group on timeout,
    stream halt, or when the BEAM dies. Both one-shot runs and streams send
    SIGINT first, then SIGTERM after `interrupt_grace_ms` (default 2,000),
    then SIGKILL after `kill_grace_ms`. Codex handles SIGINT by stopping the
    tool command it is running; on SIGTERM alone it exits and leaves that
    command behind, because codex puts each tool command and stdio MCP
    server in its own process group (#119). Pass `interrupt_signal: :int`
    and `interrupt_grace_ms` in `runner_options` to change the one-shot
    grace; streams always use the default.

    The default `CodexWrapper.Runner.Port` also sends SIGINT first on both
    paths, but signals only the `codex` process. Neither runner stops
    descendants that leave codex's process group or ignore these signals;
    on Linux, forcola's cgroup option is the backstop.

    Prompts use a private file opened and unlinked by a short shell launcher
    before it execs codex. The launcher retains the target's process group and
    one-shot signal schedule. Without prompt input, forcola closes stdin
    immediately after spawn, so commands reading stdin see EOF.

    forcola requires a finite whole-run bound. Synchronous commands with
    no `:timeout` use `forcola_default_timeout_ms` (five minutes by
    default); streams use `forcola_default_stream_timeout_ms` (one hour
    by default), so a long active turn is not cut off after five minutes.

    `stream_lines/4` is backed by `Forcola.Stream.lines/2`, so the
    NDJSON paths (`Exec.stream/2` and friends) get the same group kill
    on halt, timeout, or BEAM death. Unlike `Forcola.Stream.lines/2`,
    it does not raise on a non-zero exit: it ends the stream with an
    `{:error, {:exit_status, code}}`, `{:error, {:spawn, reason}}` or
    `{:error, {:signal, signal}}` item, as the `CodexWrapper.Runner`
    contract specifies.

    This module compiles only when `forcola` is a dependency. Select it
    with `config :codex_wrapper, runner: CodexWrapper.Runner.Forcola`
    (or the `:forcola` shorthand). forcola is POSIX-only.
    """

    @behaviour CodexWrapper.Runner

    alias CodexWrapper.{Argv, StdinFile}

    # forcola requires a mandatory whole-run bound. When the caller sets no
    # timeout we still want group-kill-on-BEAM-death, so we substitute a
    # configurable default rather than falling back to the leaky path.
    @default_timeout_ms 300_000
    @default_stream_timeout_ms 3_600_000
    # Matches the Port runner's SIGINT grace before SIGTERM.
    @default_interrupt_grace_ms 2_000
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
      bound = timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)

      with :ok <- validate_options(Keyword.take(opts, @transport_options)) do
        with_launch(binary, args, opts, fn argv ->
          Forcola.run(argv, one_shot_opts(opts, timeout))
          |> project(bound, false)
        end)
      end
    end

    @impl true
    def run_observed(binary, args, opts, timeout, target) do
      bound = timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)

      with :ok <- validate_options(Keyword.take(opts, @transport_options)) do
        with_launch(binary, args, opts, fn argv ->
          forcola_opts =
            one_shot_opts(opts, timeout)
            |> Keyword.put(:merge_stderr, false)
            |> Keyword.put(:output_observer, target)

          Forcola.run(argv, forcola_opts)
          |> project(bound, true)
        end)
      end
    end

    @impl true
    def validate_evidence do
      validate_options(max_output_bytes: 1_048_576)
    end

    @impl true
    def run_evidenced(binary, args, opts, timeout, target) do
      bound = timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)

      # Capability and argv failures carry no fabricated native child status.
      result =
        with :ok <- validate_evidence(),
             :ok <- validate_options(Keyword.take(opts, @transport_options)) do
          with_launch(binary, args, opts, fn argv ->
            forcola_opts =
              one_shot_opts(opts, timeout)
              |> Keyword.put(:merge_stderr, false)
              |> Keyword.put(:output_observer, target)
              |> Keyword.put_new(:idle_timeout_ms, @default_timeout_ms)
              |> Keyword.put_new(:max_output_bytes, 1_048_576)

            outcome = Forcola.run(argv, forcola_opts)
            {project(outcome, bound, true), evidence(outcome)}
          end)
        end

      case result do
        {:error, {:spawn, reason}} = error -> {error, %{termination: {:spawn, reason}}}
        {:error, _} = error -> {error, %{termination: :pre_spawn}}
        outcome -> outcome
      end
    end

    defp with_launch(binary, args, opts, fun) do
      with :ok <- Argv.validate(binary, args, opts),
           {:ok, binary} <- prompt_executable(binary, opts) do
        StdinFile.with_file(opts, &validated_launch(launch(binary, args, &1), opts, fun))
      end
    end

    # Spawning the stdin launcher succeeds even if its later exec would fail.
    # Resolve that executable first to retain the native runner's spawn-error
    # contract. Keep exit 126/127 from a successfully started target unchanged.
    # The OS still owns the final check if the executable changes after this one.
    defp prompt_executable(binary, opts) do
      if is_binary(opts[:stdin]) do
        with {:ok, directory} <- execution_directory(opts[:cd]) do
          resolve_executable(binary, opts, directory)
        end
      else
        {:ok, binary}
      end
    end

    defp resolve_executable(binary, opts, directory) do
      binary
      |> executable_candidates(opts, directory)
      |> Enum.find_value(&System.find_executable/1)
      |> case do
        nil -> {:error, {:spawn, :executable_not_found}}
        path -> {:ok, path}
      end
    end

    defp execution_directory(nil), do: current_directory()

    defp execution_directory(directory) do
      directory = to_string(directory)

      if Path.type(directory) == :absolute do
        {:ok, directory}
      else
        with {:ok, cwd} <- current_directory(), do: {:ok, Path.absname(directory, cwd)}
      end
    end

    defp current_directory do
      case File.cwd() do
        {:ok, directory} -> {:ok, directory}
        {:error, reason} -> {:error, {:spawn, {:cwd, reason}}}
      end
    end

    defp executable_candidates(binary, opts, directory) do
      if String.contains?(binary, "/") do
        [Path.absname(binary, directory)]
      else
        opts
        |> executable_path()
        |> String.split(":")
        |> Enum.map(&Path.absname(Path.join(&1, binary), directory))
      end
    end

    defp executable_path(opts) do
      inherited = if opts[:env_mode] == :replace, do: nil, else: System.get_env("PATH")

      opts
      |> Keyword.get(:env, [])
      |> CodexWrapper.Config.validate_env!()
      |> Enum.reduce(inherited, fn
        {"PATH", value}, _previous -> if is_binary(value), do: value
        _entry, previous -> previous
      end)
      |> Kernel.||(default_executable_path())
    end

    defp default_executable_path do
      executable = System.find_executable("getconf") || "/usr/bin/getconf"

      case System.cmd(executable, ["PATH"], stderr_to_stdout: true) do
        {path, 0} -> String.trim(path)
        _ -> "/bin:/usr/bin"
      end
    rescue
      ErlangError -> "/bin:/usr/bin"
    end

    defp validated_launch([executable | args] = argv, opts, fun) do
      with :ok <- Argv.validate(executable, args, opts) do
        fun.(argv)
      end
    end

    # exec retains the process group and signal schedule owned by Forcola.
    # The only prompt reference in argv is its private temporary path.
    # The temporary EXIT trap maps fatal redirection failures to status 125
    # without `command exec`, which can hang on macOS's Bash 3.2.
    @stdin_launcher """
    stdin_file=$1
    stdin_directory=$2
    shift 2
    trap 'exit 125' 0
    exec <"$stdin_file"
    trap - 0
    /bin/rm -f -- "$stdin_file" || exit 125
    /bin/rmdir -- "$stdin_directory" || exit 125
    exec "$@"
    """

    @doc false
    def launch(binary, args, nil), do: [binary | args]

    def launch(binary, args, path),
      do: [
        "/bin/sh",
        "-c",
        @stdin_launcher,
        "codex-wrapper",
        path,
        Path.dirname(path),
        binary | args
      ]

    @doc false
    # One-shot options for `Forcola.run/2`. Without caller interrupt options,
    # SIGINT goes to the group first: codex stops its own tool commands on
    # SIGINT and only exits on SIGTERM (#119).
    @spec one_shot_opts(keyword(), timeout() | nil) :: keyword()
    def one_shot_opts(opts, timeout) do
      opts
      |> Keyword.take([
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
      |> default_interrupt()
      |> one_shot_env()
      |> Keyword.put(
        :timeout_ms,
        timeout || Keyword.get_lazy(opts, :timeout_ms, fn -> effective_timeout(nil) end)
      )
      |> Keyword.put(:merge_stderr, merge_stderr?(opts))
    end

    # `Forcola.run/2` takes string values only. An unset (`nil` or `false`)
    # is applied by replacing the environment with the computed one: the
    # VM's environment (none under `env_mode: :replace`) with each entry
    # applied in order.
    defp one_shot_env(opts) do
      {sets, unsets} = split_env(Keyword.get(opts, :env, []))

      if unsets == [] do
        if Keyword.has_key?(opts, :env), do: Keyword.put(opts, :env, sets), else: opts
      else
        base = if opts[:env_mode] == :replace, do: %{}, else: System.get_env()

        env =
          base
          |> Map.drop(unsets)
          |> Map.merge(Map.new(sets))
          |> Enum.sort()

        opts |> Keyword.put(:env, env) |> Keyword.put(:env_mode, :replace)
      end
    end

    # The last entry for a name wins. Returns the names to set, in order,
    # and the names to unset.
    defp split_env(env) do
      final =
        env
        |> CodexWrapper.Config.validate_env!()
        |> Enum.reduce({%{}, []}, fn {name, value}, {values, order} ->
          {Map.put(values, name, value), [name | List.delete(order, name)]}
        end)

      {values, order} = final
      names = Enum.reverse(order)

      {for(name <- names, is_binary(values[name]), do: {name, values[name]}),
       for(name <- names, values[name] == false, do: name)}
    end

    defp default_interrupt(opts) do
      if Keyword.has_key?(opts, :interrupt_signal) or Keyword.has_key?(opts, :interrupt_grace_ms),
        do: opts,
        else: opts ++ [interrupt_signal: :int, interrupt_grace_ms: @default_interrupt_grace_ms]
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

      {sets, unsets} = split_env(Keyword.get(opts, :env, []))

      stream_opts =
        [timeout_ms: timeout, merge_stderr: merge_stderr?(opts)] ++
          Keyword.take(opts, [:cd]) ++
          if(sets == [], do: [], else: [env: sets]) ++
          [interrupt_signal: :int, interrupt_grace_ms: @default_interrupt_grace_ms]

      stream_opts =
        if idle_timeout_ms,
          do: Keyword.put(stream_opts, :idle_timeout_ms, idle_timeout_ms),
          else: stream_opts

      Stream.flat_map([nil], fn _ ->
        validated_stream(binary, args, opts, stream_opts, unsets)
      end)
    end

    defp validated_stream(binary, args, opts, stream_opts, unsets) do
      # Stream always inherits the environment; env -u applies its removals.
      opts = Keyword.delete(opts, :env_mode)

      with :ok <- Argv.validate(binary, args, opts),
           {:ok, binary} <- prompt_executable(binary, opts) do
        StdinFile.stream(opts, fn path ->
          argv = env_unset_prefix(unsets) ++ launch(binary, args, path)
          stream_with_stdin(argv, stream_opts)
        end)
      else
        {:error, _} = error ->
          [error]
      end
    end

    defp stream_with_stdin(argv, opts) do
      case validated_launch(argv, opts, &Forcola.Stream.lines(&1, opts)) do
        {:error, _} = error -> [error]
        stream -> halt_on_error(stream, opts[:timeout_ms], opts[:idle_timeout_ms])
      end
    end

    # A stream removes variables with `env -u`, which then execs the target
    # in the same process group.
    defp env_unset_prefix([]), do: []

    defp env_unset_prefix(names),
      do: ["/usr/bin/env" | Enum.flat_map(names, &["-u", &1])]

    # `Forcola.Stream.lines/2` raises on a non-zero exit, a signal, a
    # timeout, or a spawn failure. The wrapper's streaming contract ends
    # the stream with an error item instead (see `CodexWrapper.Runner`),
    # so translate.
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
          true -> exit_error(error)
        end
    end

    # A run that never started carries a spawn reason; one that ended badly
    # carries its exit status or signal. Each ends the stream with one error
    # item after the lines the process produced.
    defp exit_error(%Forcola.Stream.Error{reason: reason}) when not is_nil(reason),
      do: {[{:error, {:spawn, reason}}], :done}

    defp exit_error(%Forcola.Stream.Error{status: code}) when is_integer(code) and code != 0,
      do: {[{:error, {:exit_status, code}}], :done}

    defp exit_error(%Forcola.Stream.Error{status: {:signal, _} = signal}),
      do: {[{:error, signal}], :done}

    defp exit_error(_error), do: {:halt, :done}

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
