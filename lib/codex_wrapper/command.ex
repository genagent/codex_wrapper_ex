defmodule CodexWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. Uses Port instead of System.cmd to close stdin
  (Codex CLI hangs if stdin is inherited from parent).
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

  defp execute_cmd(mod, binary, args, opts, timeout) do
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

  defp run_with_closed_stdin(binary, args, opts) do
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    # Build the command string with stdin redirected from /dev/null
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    shell_cmd = "#{binary} #{escaped_args} < /dev/null 2>&1"

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, args: ["-c", shell_cmd]]
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

  defp shell_escape(arg) do
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
