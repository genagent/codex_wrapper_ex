defmodule CodexWrapper.Result do
  @moduledoc """
  Result from a completed exec command.

  Maps to the Rust `CommandOutput` -- the raw output from `System.cmd`.
  Legacy execution merges stderr into stdout. Opt-in observed execution
  preserves the exact bytes in separate stdout and stderr fields.
  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          success: boolean()
        }

  defstruct [
    :stdout,
    :stderr,
    :exit_code,
    success: false
  ]

  @doc """
  Build a result from `System.cmd/3` output.

  `System.cmd` with `:stderr_to_stdout` merges stderr into stdout,
  so `stderr` is always `""` in that case.
  """
  @spec from_cmd({String.t(), non_neg_integer()}, keyword()) :: t()
  def from_cmd({output, exit_code}, _opts \\ []) do
    %__MODULE__{
      stdout: output,
      stderr: "",
      exit_code: exit_code,
      success: exit_code == 0
    }
  end
end
