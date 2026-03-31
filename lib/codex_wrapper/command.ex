defmodule CodexWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. This is the Elixir equivalent of the Rust
  `CodexCommand` trait.
  """

  @type args :: [String.t()]

  @callback args(command :: struct()) :: args()
  @callback parse_output(stdout :: String.t(), exit_code :: non_neg_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Run a command synchronously via `System.cmd`.

  Returns the parsed output on success.
  """
  @spec run(module(), struct(), CodexWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = CodexWrapper.Config.base_args(config) ++ mod.args(command)
    opts = CodexWrapper.Config.cmd_opts(config)

    execute_cmd(mod, config.binary, all_args, opts, config.timeout)
  end

  defp execute_cmd(mod, binary, args, opts, nil) do
    case System.cmd(binary, args, opts) do
      {stdout, 0} -> mod.parse_output(stdout, 0)
      {stdout, code} -> mod.parse_output(stdout, code)
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd, e}}
  end

  defp execute_cmd(mod, binary, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(binary, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
      nil -> {:error, {:timeout, timeout}}
    end
  end
end
