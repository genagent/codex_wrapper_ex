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
  """

  @behaviour CodexWrapper.Runner

  alias CodexWrapper.Command

  @impl true
  def run(binary, args, opts, timeout) do
    task = Task.async(fn -> run_with_closed_stdin(binary, args, opts) end)
    effective_timeout = timeout || :infinity

    case Task.yield(task, effective_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, code}} -> {:ok, {stdout, code}}
      nil -> {:error, :timeout}
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
