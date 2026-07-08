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
  abandons the OS process group; `CodexWrapper.Runner.Forcola` kills it.
  """
  @spec run(module(), struct(), CodexWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = CodexWrapper.Config.base_args(config) ++ mod.args(command)
    opts = CodexWrapper.Config.cmd_opts(config)

    case CodexWrapper.Runner.impl().run(config.binary, all_args, opts, config.timeout) do
      {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
      {:error, :timeout} -> {:error, {:timeout, config.timeout}}
      {:error, reason} -> {:error, reason}
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
end
