defmodule CodexWrapper.LastMessage do
  @moduledoc """
  Run a command and read its final agent message from `--output-last-message`.

      {:ok, text, result} =
        CodexWrapper.Exec.new("Summarize the diff in one paragraph")
        |> CodexWrapper.LastMessage.run(CodexWrapper.Config.new())

  Supports `Exec`, `ExecResume`, `ExecFork` and `Review`. An explicit
  `output_last_message/2` path is used as supplied and remains the caller's
  responsibility. Otherwise this module owns a temporary file for the run.
  Text is returned verbatim, independently of stdout and stderr.

  A zero exit with a missing or empty file returns
  `{:error, {:no_last_message, result}}`. A non-zero exit returns
  `{:error, {:process_failed, text, result}}`, with `""` for a missing file.
  With codex-cli 0.165.0 a failed turn exits non-zero without writing the file,
  so an owned file is left empty and the text in `{:process_failed, text, result}` is `""`.
  Other read failures return `{:error, {:last_message_read, reason, result}}`.
  File creation failures return `{:error, {:last_message_file, reason}}`;
  runner errors are returned unchanged.
  """

  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, Result, Review}

  @type command :: Exec.t() | ExecResume.t() | ExecFork.t() | Review.t()
  @type error ::
          {:no_last_message, Result.t()}
          | {:process_failed, String.t(), Result.t()}
          | {:last_message_read, File.posix(), Result.t()}
          | {:last_message_file, File.posix()}
          | term()

  @doc """
  Run `command` and return its final agent message and original result.

  Options are passed to the command's `execute/3`, including observation
  options. The owned file is created with mode `0600` in `System.tmp_dir!/0`
  and removed after execution on success, failure or raise. Explicit paths
  are neither created ahead of execution nor removed by this module.
  """
  @spec run(command(), Config.t(), keyword()) ::
          {:ok, String.t(), Result.t()} | {:error, error()}
  def run(command, %Config{} = config, opts \\ []) when is_list(opts) do
    module = command_module(command)

    case command.output_last_message do
      nil -> with_message_file(fn path -> execute(module, command, config, opts, path) end)
      path -> execute(module, command, config, opts, path)
    end
  end

  defp command_module(%Exec{}), do: Exec
  defp command_module(%ExecResume{}), do: ExecResume
  defp command_module(%ExecFork{}), do: ExecFork
  defp command_module(%Review{}), do: Review

  defp execute(module, command, config, opts, path) do
    command
    |> module.output_last_message(path)
    |> module.execute(config, opts)
    |> case do
      {:ok, %Result{} = result} -> read_message(path, result)
      {:error, _reason} = error -> error
    end
  end

  defp read_message(path, result) do
    case File.read(path) do
      {:ok, text} -> outcome(text, result)
      {:error, :enoent} -> outcome("", result)
      {:error, reason} -> {:error, {:last_message_read, reason, result}}
    end
  end

  defp outcome(text, %Result{exit_code: code} = result) when code != 0,
    do: {:error, {:process_failed, text, result}}

  defp outcome("", result), do: {:error, {:no_last_message, result}}
  defp outcome(text, result), do: {:ok, text, result}

  defp with_message_file(fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-wrapper-last-message-#{System.pid()}-#{System.unique_integer([:positive])}.txt"
      )

    with :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      try do
        fun.(path)
      after
        File.rm(path)
      end
    else
      {:error, reason} ->
        File.rm(path)
        {:error, {:last_message_file, reason}}
    end
  end
end
