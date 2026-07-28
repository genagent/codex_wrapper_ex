defmodule CodexWrapper.Runner.Port do
  @moduledoc """
  Default runner: a `/bin/sh` `Port` with stdin redirected from
  `/dev/null` (Codex CLI hangs if stdin is inherited from the parent),
  wrapped in a `Task` for timeout enforcement.

  This is the execution path the library has always used. On a timeout it
  brutal-kills the `Task`, which closes the port but sends no signal to the
  OS process group. `codex` and any subprocess it spawned (stdio MCP
  servers, tool helpers) may keep running until they next touch a closed
  pipe. For strict termination, use `CodexWrapper.Runner.Forcola` (see
  `CodexWrapper.Runner` and #48).

  `stream_lines/4` uses the same `/bin/sh` wrapper in `:line` mode, and
  treats `timeout` as an *idle* bound: the wait for the next line, not
  for the whole run. That is what the streaming paths have always done.
  """

  @behaviour CodexWrapper.Runner

  alias CodexWrapper.Command

  # Idle bound between output frames when the caller sets no timeout.
  @default_idle_timeout_ms 300_000

  # How long to wait for the port to confirm it closed when the stream halts.
  @close_timeout_ms 5_000

  # A line longer than this is split across frames; the fragments are
  # dropped, matching the pre-Runner streaming paths.
  @max_line_bytes 1_048_576

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
    idle_timeout = timeout || @default_idle_timeout_ms

    port_opts =
      [
        :binary,
        :exit_status,
        {:line, @max_line_bytes},
        {:args, Command.shell_cmd_args(binary, args)}
      ]
      |> maybe_add(:cd, stream_cd(opts))
      |> maybe_add_env(Keyword.get(opts, :env, []))

    Stream.resource(
      fn -> {Port.open({:spawn_executable, "/bin/sh"}, port_opts), :running} end,
      fn state -> next_line(state, idle_timeout) end,
      &close_port/1
    )
  end

  defp next_line({port, :running} = state, idle_timeout) do
    receive do
      {^port, {:data, {:eol, line}}} -> {[line], state}
      {^port, {:data, {:noeol, _partial}}} -> {[], state}
      {^port, {:exit_status, _code}} -> {:halt, {port, :exited}}
    after
      idle_timeout -> {:halt, state}
    end
  end

  # The process exited on its own, so the port is already gone. Asking it
  # to close would just block until `@close_timeout_ms` for a `:closed`
  # that can never arrive.
  defp close_port({_port, :exited}), do: :ok

  # Halted early (`Enum.take/2`, an idle timeout, an exception downstream)
  # with the process still alive: close the port, which closes its stdout
  # and leaves `codex` to die when it next writes. Use
  # `CodexWrapper.Runner.Forcola` if you need the group killed outright.
  defp close_port({port, :running}) do
    send(port, {self(), :close})

    receive do
      {^port, :closed} -> :ok
    after
      @close_timeout_ms -> :ok
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
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Command.shell_cmd_args(binary, args, capture_stderr: true)
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

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp maybe_add_env(opts, []), do: opts
  defp maybe_add_env(opts, env), do: [{:env, env} | opts]
end
