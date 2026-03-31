defmodule CodexWrapper.Commands.Apply do
  @moduledoc """
  Apply command — apply an agent diff as git apply.

  Wraps `codex apply <task-id>`.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/repo")

      {:ok, output} = CodexWrapper.Commands.Apply.execute(config, "abc-123")
  """

  alias CodexWrapper.Config

  @doc """
  Apply the diff from the given task ID.
  """
  @spec execute(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(%Config{} = config, task_id) when is_binary(task_id) do
    args = Config.base_args(config) ++ ["apply", task_id]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Build the argument list for the apply command.
  """
  @spec build_args(String.t()) :: [String.t()]
  def build_args(task_id) when is_binary(task_id) do
    ["apply", task_id]
  end
end
