defmodule CodexWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. Uses Port instead of System.cmd to close stdin
  (Codex CLI hangs if stdin is inherited from parent).

  ## Runners

  The one-shot execution path selects a runner at call time:

    * the default `:task` runner opens a `/bin/sh` `Port` with stdin
      redirected from `/dev/null` and bounds the run with a BEAM
      `Task` timeout. A timeout brutal-kills the BEAM task; the
      `codex` process it launched (and any MCP-server children) can
      orphan.
    * the optional `:forcola` runner routes the run through
      [`forcola`](https://hexdocs.pm/forcola), a Rust shim that puts
      the child in its own process group and kills the whole group
      (SIGTERM then SIGKILL) on timeout, on close, or when the BEAM
      dies. This reaps `codex` together with the stdio MCP servers it
      spawns. `forcola` is a POSIX-only optional dependency.

  Select the forcola runner with:

      config :codex_wrapper, runner: :forcola

  The runner is `:forcola` only when that config is set *and* the
  `forcola` dependency is loaded; otherwise the default `:task`
  runner is used, so nothing changes for consumers that do not opt
  in. `forcola` requires a finite timeout; when `config.timeout` is
  `nil` the one-shot forcola run falls back to
  `config :codex_wrapper, forcola_default_timeout_ms: <ms>`
  (default `#{300_000}`), instead of running unbounded.
  """

  @type args :: [String.t()]

  @callback args(command :: struct()) :: args()
  @callback parse_output(stdout :: String.t(), exit_code :: non_neg_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Run a command with stdin closed.

  Returns the parsed output on success.
  """
  @spec run(module(), struct(), CodexWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = CodexWrapper.Config.base_args(config) ++ mod.args(command)
    opts = CodexWrapper.Config.cmd_opts(config)

    execute_cmd(mod, config.binary, all_args, opts, config.timeout)
  end

  @default_forcola_timeout_ms 300_000

  defp execute_cmd(mod, binary, args, opts, timeout) do
    if forcola_enabled?() do
      run_with_forcola(mod, binary, args, opts, timeout)
    else
      run_with_task(mod, binary, args, opts, timeout)
    end
  end

  defp run_with_task(mod, binary, args, opts, timeout) do
    task =
      Task.async(fn ->
        run_with_closed_stdin(binary, args, opts)
      end)

    effective_timeout = timeout || :infinity

    case Task.yield(task, effective_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
      nil -> {:error, {:timeout, timeout}}
    end
  end

  # Run through the forcola shim so the whole `codex` process group is
  # killed on timeout, on close, or when the BEAM dies. `forcola` runs
  # the child directly (no `/bin/sh` wrapper) with no stdin writer, so
  # `codex` sees EOF naturally -- the same effect the `< /dev/null`
  # redirect gives the default runner. `merge_stderr: true` mirrors the
  # `2>&1` merge the default path uses so `parse_output/2` sees the same
  # combined stream.
  defp run_with_forcola(mod, binary, args, opts, timeout) do
    timeout_ms = timeout || forcola_default_timeout_ms()

    run_opts =
      [timeout_ms: timeout_ms, merge_stderr: true]
      |> maybe_add(:cd, Keyword.get(opts, :cd))
      |> maybe_add_env(Keyword.get(opts, :env, []))

    case Forcola.run([binary | args], run_opts) do
      {:ok, result} -> mod.parse_output(result.stdout, forcola_exit_code(result.status))
      {:error, {:timeout, _partial}} -> {:error, {:timeout, timeout_ms}}
      {:error, {:spawn, reason}} -> {:error, {:spawn, reason}}
    end
  end

  defp forcola_enabled? do
    Application.get_env(:codex_wrapper, :runner) == :forcola and Code.ensure_loaded?(Forcola)
  end

  defp forcola_default_timeout_ms do
    Application.get_env(:codex_wrapper, :forcola_default_timeout_ms, @default_forcola_timeout_ms)
  end

  # `Forcola.Result` reports a normal exit as an integer code and a
  # signalled death as `{:signal, n}`. Map a signal to the conventional
  # `128 + n` shell code so `parse_output/2` treats it as a non-zero
  # exit; `{:signal, :unconfirmed}` (death not confirmed) maps to `1`.
  defp forcola_exit_code(code) when is_integer(code), do: code
  defp forcola_exit_code({:signal, n}) when is_integer(n), do: 128 + n
  defp forcola_exit_code({:signal, _}), do: 1

  defp run_with_closed_stdin(binary, args, opts) do
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: shell_cmd_args(binary, args, capture_stderr: true)
      ]
      |> maybe_add(:cd, cd)
      |> maybe_add_env(env)

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    collect_port_output(port, "")
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data)

      {^port, {:exit_status, code}} ->
        {acc, code}
    end
  end

  # Build the `:args` list for a `Port.open({:spawn_executable, "/bin/sh"}, ...)`
  # call that runs `binary` with `args` and redirects stdin from `/dev/null`.
  # Shared by the execute path (`run/3`) and the streaming paths
  # (`Exec.stream/2`, `ExecResume.stream/2`) so the stdin-closing
  # mechanism lives in one place.
  #
  # Pass `capture_stderr: true` to merge stderr into stdout (execute path
  # collects all output before parsing). Leave it off for streaming so
  # stderr flows to the parent's stderr without contaminating NDJSON on stdout.
  @doc false
  @spec shell_cmd_args(String.t(), [String.t()], keyword()) :: [String.t()]
  def shell_cmd_args(binary, args, opts \\ []) do
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    redirect = if Keyword.get(opts, :capture_stderr, false), do: " 2>&1", else: ""
    shell_cmd = "#{binary} #{escaped_args} < /dev/null#{redirect}"
    ["-c", shell_cmd]
  end

  @doc false
  def shell_escape(arg) do
    if String.contains?(arg, ["'", " ", "\"", "\\", "(", ")", "$", "`", "!", "&", "|", ";", "\n"]) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp maybe_add_env(opts, []), do: opts
  defp maybe_add_env(opts, env), do: [{:env, env} | opts]
end
