defmodule CodexWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. Synchronous execution routes through the configured
  `CodexWrapper.Runner`; the default runner closes stdin (Codex CLI hangs
  if stdin is inherited from the parent).
  """

  @type args :: [String.t()]

  @callback args(command :: struct()) :: args()
  @callback parse_output(stdout :: String.t(), exit_code :: non_neg_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Run a command synchronously through the configured `CodexWrapper.Runner`.

  Returns the parsed output on success. On timeout the default runner
  signals the `codex` process (SIGINT, then SIGTERM, then SIGKILL; see
  `CodexWrapper.Runner.Port`). `CodexWrapper.Runner.Forcola` kills the
  whole process group.
  """
  @spec run(module(), struct(), CodexWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = CodexWrapper.Config.base_args(config) ++ mod.args(command)
    opts = CodexWrapper.Config.cmd_opts(config)

    runner = CodexWrapper.Runner.impl()

    case runner.run(config.binary, all_args, opts, config.timeout) do
      {:ok, {stdout, code}} ->
        mod.parse_output(stdout, code)

      {:error, :timeout} ->
        # Report the bound that actually elapsed, which is not always
        # `config.timeout` -- Runner.Forcola substitutes a finite default
        # when the caller set none.
        {:error, {:timeout, CodexWrapper.Runner.effective_timeout(runner, config.timeout)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Seconds the watchdog waits after SIGINT before SIGTERM, and after SIGTERM
  # before SIGKILL. Fixed: the cleanup schedule is not a configuration surface.
  @int_grace_s 2
  @term_grace_s 1

  # Build the `:args` list for a `Port.open({:spawn_executable, "/bin/sh"}, ...)`
  # call that runs `binary` with `args`, redirects its stdin from `/dev/null`,
  # and cleans it up when the port goes away. Shared by the execute path
  # (`run/3`) and the streaming paths (`Exec.stream/2`, `ExecResume.stream/2`)
  # so the stdin-closing and cleanup mechanism lives in one place.
  #
  # Pass `capture_stderr: true` to merge stderr into stdout (execute path
  # collects all output before parsing). Leave it off for streaming so
  # stderr flows to the parent's stderr without contaminating NDJSON on stdout.
  #
  # The shell is a small supervisor with three processes:
  #
  #   * the native target, a background job started from `"$@"` (so a missing
  #     executable is still shell status 127 and a non-executable one 126);
  #   * a watchdog subshell that blocks in `read` on the Port's stdin pipe,
  #     which the supervisor saved on fd 3 before backgrounding anything (a
  #     background job otherwise gets /dev/null as stdin). The BEAM holds the
  #     only write end, so EOF means the port was closed or the BEAM died;
  #   * the supervisor itself, which waits for the target, keeps its status,
  #     and kills and reaps the watchdog.
  #
  # On EOF the watchdog signals the target pid: INT, SIGTERM after
  # @int_grace_s, SIGKILL after a further @term_grace_s. Only the target is
  # signalled. fd 3 is closed in the target and the supervisor; the watchdog
  # and the supervisor's own stdout/stderr go to /dev/null after launch so
  # neither can hold or write into the application's output.
  #
  # A POSIX non-interactive shell starts a background job with SIGINT and
  # SIGQUIT ignored. A target that installs its own SIGINT handler (which is
  # what lets Codex clean up tool children in other process groups) still
  # receives INT; one that does not only stops at the SIGTERM step.
  #
  # Signalling is by pid, so a pid recycled between the target's exit and the
  # watchdog's kill is a residual risk. The supervisor kills the watchdog the
  # moment the target is reaped, which keeps that window short but does not
  # remove it.
  #
  # /bin/sleep is absolute because callers may replace PATH. Without it the
  # watchdog stops after INT instead of escalating at once.
  @doc false
  @spec shell_cmd_args(String.t(), [String.t()], keyword()) :: [String.t()]
  def shell_cmd_args(binary, args, opts \\ []) do
    target_redirects =
      if Keyword.get(opts, :capture_stderr, false),
        do: "</dev/null 3<&- 2>&1",
        else: "</dev/null 3<&-"

    # sh -c consumes the first positional argument as $0. Keep a deliberate
    # label there so "$@" includes the executable and every argument verbatim.
    ["-c", supervisor_script(target_redirects), "codex-wrapper", binary | args]
  end

  defp supervisor_script(target_redirects) do
    """
    exec 3<&0
    "$@" #{target_redirects} &
    t=$!
    (
      while read -r _line; do :; done
      kill -s INT "$t" || exit 0
      [ -x /bin/sleep ] || exit 0
      /bin/sleep #{@int_grace_s}
      kill -s TERM "$t" || exit 0
      /bin/sleep #{@term_grace_s}
      kill -s KILL "$t"
      exit 0
    ) <&3 3<&- >/dev/null 2>&1 &
    w=$!
    exec 3<&- >/dev/null 2>&1
    wait "$t"
    s=$?
    kill "$w"
    wait "$w"
    exit "$s"
    """
  end

  @doc false
  def shell_escape(arg) do
    if String.contains?(arg, ["'", " ", "\"", "\\", "(", ")", "$", "`", "!", "&", "|", ";", "\n"]) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end
end
