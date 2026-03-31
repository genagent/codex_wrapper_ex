defmodule CodexWrapper do
  @moduledoc """
  Elixir wrapper for the Codex CLI.

  Provides a typed interface for executing commands against the `codex` CLI.

  ## Quick start

      # Simple one-shot exec
      {:ok, result} = CodexWrapper.exec("fix the failing test", working_dir: "/path/to/project")

      # Full control via Exec builder
      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

      CodexWrapper.Exec.new("implement the feature")
      |> CodexWrapper.Exec.model("o3")
      |> CodexWrapper.Exec.sandbox(:danger_full_access)
      |> CodexWrapper.Exec.execute(config)

  ## Binary discovery

  The `codex` binary is found via (in order):
  1. `:binary` option passed directly
  2. `CODEX_CLI` environment variable
  3. System PATH lookup
  """

  alias CodexWrapper.{Config, Exec, Result}

  @doc """
  Run an arbitrary CLI command that isn't wrapped by a dedicated module.

  This is the escape hatch for new or experimental CLI subcommands.

  ## Examples

      CodexWrapper.raw(["version"])
      CodexWrapper.raw(["exec", "fix the tests"], working_dir: "/tmp")
  """
  @spec raw([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def raw(args, opts \\ []) when is_list(args) do
    config = Config.new(opts)
    all_args = Config.base_args(config) ++ args
    cmd_opts = Config.cmd_opts(config)

    case System.cmd(config.binary, all_args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd, e}}
  end

  @doc """
  Execute a prompt non-interactively and return the result.

  Convenience wrapper that builds a `Config` and `Exec` from keyword options.
  Returns `{:ok, %Result{}}` on success or `{:error, reason}` on failure.

  ## Options

  Config options (passed to `Config.new/1`):
    * `:binary` - Path to codex binary
    * `:working_dir` - Working directory
    * `:env` - Environment variables
    * `:timeout` - Timeout in ms
    * `:verbose` - Enable verbose output

  Exec options (passed to `Exec` builder):
    * `:model` - Model name
    * `:sandbox` - Sandbox mode atom
    * `:approval_policy` - Approval policy atom
    * `:full_auto` - Enable full-auto (boolean)
    * `:dangerously_bypass_approvals_and_sandbox` - Bypass all (boolean)
    * `:cd` - Working directory for codex subprocess
    * `:skip_git_repo_check` - Skip git check (boolean)
    * `:search` - Enable web search (boolean)
    * `:ephemeral` - Ephemeral mode (boolean)
    * `:json` - JSON output (boolean)
    * `:output_schema` - Output schema path
    * `:output_last_message` - Output last message path

  ## Examples

      CodexWrapper.exec("fix the tests")
      CodexWrapper.exec("implement the feature", working_dir: "/path/to/repo", model: "o3")
  """
  @spec exec(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def exec(prompt, opts \\ []) do
    {config_opts, exec_opts} = split_opts(opts)
    config = Config.new(config_opts)
    exec = build_exec(prompt, exec_opts)
    Exec.execute(exec, config)
  end

  # --- Private ---

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp build_exec(prompt, opts) do
    exec = Exec.new(prompt)

    Enum.reduce(opts, exec, fn
      {:model, v}, e -> Exec.model(e, v)
      {:sandbox, v}, e -> Exec.sandbox(e, v)
      {:approval_policy, v}, e -> Exec.approval_policy(e, v)
      {:full_auto, true}, e -> Exec.full_auto(e)
      {:full_auto, false}, e -> e
      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        Exec.dangerously_bypass_approvals_and_sandbox(e)
      {:dangerously_bypass_approvals_and_sandbox, false}, e -> e
      {:cd, v}, e -> Exec.cd(e, v)
      {:skip_git_repo_check, true}, e -> Exec.skip_git_repo_check(e)
      {:skip_git_repo_check, false}, e -> e
      {:search, true}, e -> Exec.search(e)
      {:search, false}, e -> e
      {:ephemeral, true}, e -> Exec.ephemeral(e)
      {:ephemeral, false}, e -> e
      {:json, true}, e -> Exec.json(e)
      {:json, false}, e -> e
      {:output_schema, v}, e -> Exec.output_schema(e, v)
      {:output_last_message, v}, e -> Exec.output_last_message(e, v)
      _other, e -> e
    end)
  end
end
