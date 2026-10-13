defmodule CodexWrapper.Runner.Port do
  @moduledoc """
  Default runner: a `/bin/sh` `Port` with stdin redirected from
  `/dev/null` (Codex CLI hangs if stdin is inherited from the parent),
  wrapped in a `Task` for timeout enforcement.

  ## Cleanup

  The `/bin/sh` wrapper (`CodexWrapper.Command.shell_cmd_args/3`) runs
  `codex` as a child and watches the port's stdin pipe. Stdin reaches EOF
  when the port closes: a `run/4` timeout, a stream whole-run or idle
  timeout, an early halt, an oversized line, an exception in the stream
  consumer, death of the process that owns the port, or death of the BEAM.
  The watchdog then signals the `codex` process itself, with SIGINT first,
  SIGTERM two seconds later and SIGKILL one second after that, stopping as
  soon as the process is gone. The caller does not wait for this schedule.
  A normal exit cancels the watchdog.

  What this does and does not cover:

    * SIGINT is only useful to a program that installs its own handler.
      Codex does, and uses it to stop tool children it placed in other
      process groups. The shell starts `codex` as a background job, which
      POSIX says begins with SIGINT ignored, so a program without its own
      handler is stopped by the SIGTERM step instead.
    * Only the `codex` process is signalled. Children that Codex does not
      stop itself, daemonized processes and stdio MCP servers can outlive
      it. There is no process-tree or process-group guarantee; use
      `CodexWrapper.Runner.Forcola` for that (see `CodexWrapper.Runner`
      and #48).
    * Closing the port also closes `codex`'s stdout, so a process that
      writes while the port closes can die of a broken pipe before its
      SIGINT handler finishes.
    * Signals go to a pid. If the target exits and its pid is reused before
      the watchdog is cancelled, the watchdog could signal the wrong
      process. The supervisor cancels the watchdog as soon as it reaps the
      target, which makes this window short, not nonexistent.
    * The schedule is three seconds of sleeping, not a real-time bound.
      Without an executable `/bin/sleep` the watchdog sends SIGINT only.
    * Killing the `/bin/sh` wrapper or its watchdog directly (SIGKILL)
      defeats the mechanism.

  Cleanup needs no dependency or native binary beyond `/bin/sh`.

  `stream_lines/4` uses the same `/bin/sh` wrapper in `:line` mode. Its
  `timeout` bounds the whole run; `opts[:idle_timeout_ms]` independently
  bounds the wait between output frames. A JSONL line over 1 MiB ends the
  stream with `{:error, {:line_too_long, 1_048_576}}`.
  """

  @behaviour CodexWrapper.Runner

  alias CodexWrapper.Command

  # Idle bound between output frames when the caller sets no idle timeout.
  @default_idle_timeout_ms 300_000

  # How long to wait for the port to confirm it closed when the stream halts.
  @close_timeout_ms 5_000

  # The extra byte lets a :noeol frame prove that a line exceeded the
  # supported maximum, rather than merely reaching it before its newline.
  @max_line_bytes 1_048_576
  @port_line_bytes @max_line_bytes + 1

  @impl true
  def run(binary, args, opts, timeout) do
    task = Task.async(fn -> run_with_closed_stdin(binary, args, opts) end)
    effective_timeout = timeout || :infinity

    case Task.yield(task, effective_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, code}} -> {:ok, {stdout, code}}
      nil -> {:error, :timeout}
    end
  end

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    idle_timeout = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)

    port_opts =
      [
        :binary,
        :exit_status,
        {:line, @port_line_bytes},
        {:args, Command.shell_cmd_args(binary, args)}
      ]
      |> maybe_add(:cd, stream_cd(opts))
      |> maybe_add_env(Keyword.get(opts, :env, []))

    Stream.resource(
      fn ->
        deadline = if timeout, do: System.monotonic_time(:millisecond) + timeout
        {Port.open({:spawn_executable, "/bin/sh"}, port_opts), :running, deadline}
      end,
      fn state -> next_line(state, idle_timeout, timeout) end,
      &close_port/1
    )
  end

  defp next_line({_port, :timed_out, _deadline} = state, _idle_timeout, _timeout),
    do: {:halt, state}

  defp next_line({_port, status, _deadline} = state, _idle_timeout, _timeout)
       when status in [:failed, :failed_after_exit],
       do: {:halt, state}

  # Once the exit status was queued, every earlier output frame is also
  # queued. Drain those frames in order before ending the stream.
  defp next_line({port, :draining, deadline} = state, _idle_timeout, _timeout) do
    receive do
      {^port, {:data, {:eol, line}}} when byte_size(line) > @max_line_bytes ->
        {[{:error, {:line_too_long, @max_line_bytes}}], {port, :failed_after_exit, deadline}}

      {^port, {:data, {:eol, line}}} ->
        {[line], state}

      {^port, {:data, {:noeol, partial}}} when byte_size(partial) > @max_line_bytes ->
        {[{:error, {:line_too_long, @max_line_bytes}}], {port, :failed_after_exit, deadline}}

      {^port, {:data, {:noeol, _partial}}} ->
        {[], state}
    after
      0 -> {:halt, {port, :exited, deadline}}
    end
  end

  defp next_line({port, :running, deadline} = state, idle_timeout, timeout) do
    remaining = if deadline, do: max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      # A slow consumer may resume after the deadline even though the CLI
      # already exited. A queued exit means prior output is queued too;
      # drain it before completing rather than dropping the terminal line.
      receive do
        {^port, {:exit_status, _code}} ->
          next_line({port, :draining, deadline}, idle_timeout, timeout)
      after
        0 -> {[{:error, {:timeout, timeout}}], {port, :timed_out, deadline}}
      end
    else
      wait = min_timeout(idle_timeout, remaining)

      receive do
        {^port, {:data, {:eol, line}}} when byte_size(line) > @max_line_bytes ->
          {[{:error, {:line_too_long, @max_line_bytes}}], {port, :failed, deadline}}

        {^port, {:data, {:eol, line}}} ->
          {[line], state}

        {^port, {:data, {:noeol, partial}}} when byte_size(partial) > @max_line_bytes ->
          {[{:error, {:line_too_long, @max_line_bytes}}], {port, :failed, deadline}}

        {^port, {:data, {:noeol, _partial}}} ->
          {[], state}

        {^port, {:exit_status, _code}} ->
          {:halt, {port, :exited, deadline}}
      after
        wait ->
          reason =
            if deadline && (is_nil(idle_timeout) || remaining <= idle_timeout),
              do: {:timeout, timeout},
              else: {:idle_timeout, idle_timeout}

          {[{:error, reason}], {port, :timed_out, deadline}}
      end
    end
  end

  defp min_timeout(nil, nil), do: :infinity
  defp min_timeout(nil, other), do: other
  defp min_timeout(other, nil), do: other
  defp min_timeout(left, right), do: min(left, right)

  # The process exited on its own, so the port is already gone. Asking it
  # to close would just block until `@close_timeout_ms` for a `:closed`
  # that can never arrive.
  defp close_port({_port, :exited, _deadline}), do: :ok

  defp close_port({port, :failed_after_exit, _deadline}), do: drain_completed_port(port)

  defp close_port({port, :failed, _deadline}) do
    # The producer may have exited before the oversized frame was consumed.
    # Do not wait for a close acknowledgement from an already dead port, and
    # remove any output/exit frames left in this caller's mailbox.
    if Port.info(port) do
      send(port, {self(), :close})

      receive do
        {^port, :closed} -> :ok
        {^port, {:exit_status, _code}} -> :ok
      after
        @close_timeout_ms -> :ok
      end
    end

    drain_completed_port(port)
  end

  defp close_port({port, :draining, _deadline}) do
    drain_completed_port(port)
  end

  # Halted early (`Enum.take/2`, an idle timeout, an exception downstream)
  # with the process still alive: close the port. That closes the wrapper's
  # stdin, which starts the INT/TERM/KILL schedule described in the
  # moduledoc. This returns once the port is closed, not once `codex` is gone.
  defp close_port({port, _status, _deadline}) do
    send(port, {self(), :close})

    receive do
      {^port, :closed} -> :ok
    after
      @close_timeout_ms -> :ok
    end
  end

  # The exit status was consumed before entering :draining, so no more
  # frames can arrive. Discard any unconsumed output on an early halt to
  # avoid leaving it in a long-lived caller's mailbox.
  defp drain_completed_port(port) do
    receive do
      {^port, _message} -> drain_completed_port(port)
    after
      0 -> :ok
    end
  end

  # `Config.cmd_opts/1` hands `:cd` over as a string; `Port.open/2` has
  # always been given a charlist on the streaming paths.
  defp stream_cd(opts) do
    case Keyword.get(opts, :cd) do
      nil -> nil
      dir when is_binary(dir) -> String.to_charlist(dir)
      dir -> dir
    end
  end

  defp run_with_closed_stdin(binary, args, opts) do
    env = Keyword.get(opts, :env, [])

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Command.shell_cmd_args(binary, args, capture_stderr: true)
      ]
      |> maybe_add(:cd, stream_cd(opts))
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

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp maybe_add_env(opts, []), do: opts

  defp maybe_add_env(opts, env) do
    port_env = Enum.map(env, fn {key, value} -> {port_env_part(key), port_env_part(value)} end)
    [{:env, port_env} | opts]
  end

  defp port_env_part(value) when is_binary(value), do: String.to_charlist(value)
  defp port_env_part(value) when is_list(value), do: value
  defp port_env_part(false), do: false
end
