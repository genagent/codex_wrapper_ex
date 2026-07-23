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

  alias CodexWrapper.Commands.{Completion, Version}
  alias CodexWrapper.{Config, Exec, JsonLineEvent, Result, Review}

  @doc """
  Get the Codex CLI version.

  ## Examples

      {:ok, %{version: "codex 0.1.0", raw: "codex 0.1.0"}} = CodexWrapper.version()
  """
  @spec version(keyword()) :: {:ok, %{version: String.t(), raw: String.t()}} | {:error, term()}
  def version(opts \\ []) do
    config = Config.new(opts)
    Version.execute(config)
  end

  @doc """
  Generate a shell completion script.

  ## Examples

      {:ok, script} = CodexWrapper.completion(:zsh)
  """
  @spec completion(Completion.shell(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def completion(shell \\ :bash, opts \\ []) do
    config = Config.new(opts)
    Completion.generate(config, shell)
  end

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

  Config options (passed to `CodexWrapper.Config.new/1`):
    * `:binary` - Path to codex binary
    * `:working_dir` - Working directory
    * `:env` - Environment variables
    * `:timeout` - Timeout in ms
    * `:verbose` - Enable verbose output

  Exec options (passed to `Exec` builder):
    * `:model` - Model name
    * `:sandbox` - Sandbox mode atom
    * `:approval_policy` - Approval policy atom (`:untrusted`, `:on_request`, `:never`)
    * `:full_auto` - Deprecated; emits `--sandbox workspace-write` (boolean)
    * `:dangerously_bypass_approvals_and_sandbox` - Bypass all (boolean)
    * `:cd` - Working directory for codex subprocess
    * `:skip_git_repo_check` - Skip git check (boolean)
    * `:search` - Web search: `true` (live), `false`, or a mode atom
      (`:cached`, `:indexed`, `:live`, `:disabled`)
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

  @doc """
  Execute a prompt with `--json` and return parsed NDJSON events.

  See `exec/2` for available options.

  ## Examples

      {:ok, events} = CodexWrapper.exec_json("fix the tests")
  """
  @spec exec_json(String.t(), keyword()) :: {:ok, [JsonLineEvent.t()]} | {:error, term()}
  def exec_json(prompt, opts \\ []) do
    {config_opts, exec_opts} = split_opts(opts)
    config = Config.new(config_opts)
    exec = build_exec(prompt, exec_opts)
    Exec.execute_json(exec, config)
  end

  @doc """
  Execute a prompt and return a lazy stream of `%JsonLineEvent{}`.

  See `exec/2` for available options.

  ## Examples

      CodexWrapper.stream("fix the tests")
      |> Enum.each(fn event -> IO.inspect(event.event_type) end)
  """
  @spec stream(String.t(), keyword()) :: Enumerable.t()
  def stream(prompt, opts \\ []) do
    {config_opts, exec_opts} = split_opts(opts)
    config = Config.new(config_opts)
    exec = build_exec(prompt, exec_opts)
    Exec.stream(exec, config)
  end

  @doc """
  Run a code review via `codex exec review`.

  Convenience wrapper that builds a `Config` and `Review` from keyword options.
  Returns `{:ok, %Result{}}` on success or `{:error, reason}` on failure.

  ## Options

  Config options (passed to `CodexWrapper.Config.new/1`):
    * `:binary` - Path to codex binary
    * `:working_dir` - Working directory
    * `:env` - Environment variables
    * `:timeout` - Timeout in ms
    * `:verbose` - Enable verbose output

  Review options (passed to `Review` builder):
    * `:prompt` - Additional review context
    * `:uncommitted` - Review uncommitted changes (boolean)
    * `:base` - Compare against base branch
    * `:commit` - Review a specific commit
    * `:title` - PR/review title
    * `:model` - Model name
    * `:full_auto` - Deprecated; emits `--sandbox workspace-write` (boolean)
    * `:dangerously_bypass_approvals_and_sandbox` - Bypass all (boolean)
    * `:skip_git_repo_check` - Skip git check (boolean)
    * `:ephemeral` - Ephemeral mode (boolean)
    * `:output_schema` - Output schema path
    * `:json` - JSON output (boolean)
    * `:output_last_message` - Output last message path

  ## Examples

      CodexWrapper.review(uncommitted: true, working_dir: "/path/to/repo")
      CodexWrapper.review(base: "main", model: "o3")
  """
  @spec review(keyword()) :: {:ok, Result.t()} | {:error, term()}
  def review(opts \\ []) do
    {config_opts, review_opts} = split_opts(opts)
    config = Config.new(config_opts)
    review = build_review(review_opts)
    Review.execute(review, config)
  end

  # --- Private ---

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp build_review(opts) do
    review = Review.new()

    Enum.reduce(opts, review, fn
      {:prompt, v}, r ->
        Review.prompt(r, v)

      {:uncommitted, true}, r ->
        Review.uncommitted(r)

      {:uncommitted, false}, r ->
        r

      {:base, v}, r ->
        Review.base(r, v)

      {:commit, v}, r ->
        Review.commit(r, v)

      {:title, v}, r ->
        Review.title(r, v)

      {:model, v}, r ->
        Review.model(r, v)

      {:full_auto, true}, r ->
        Review.full_auto(r)

      {:full_auto, false}, r ->
        r

      {:dangerously_bypass_approvals_and_sandbox, true}, r ->
        Review.dangerously_bypass_approvals_and_sandbox(r)

      {:dangerously_bypass_approvals_and_sandbox, false}, r ->
        r

      {:skip_git_repo_check, true}, r ->
        Review.skip_git_repo_check(r)

      {:skip_git_repo_check, false}, r ->
        r

      {:ephemeral, true}, r ->
        Review.ephemeral(r)

      {:ephemeral, false}, r ->
        r

      {:output_schema, v}, r ->
        Review.output_schema(r, v)

      {:json, true}, r ->
        Review.json(r)

      {:json, false}, r ->
        r

      {:output_last_message, v}, r ->
        Review.output_last_message(r, v)

      _other, r ->
        r
    end)
  end

  defp build_exec(prompt, opts) do
    exec = Exec.new(prompt)

    Enum.reduce(opts, exec, fn
      {:model, v}, e ->
        Exec.model(e, v)

      {:sandbox, v}, e ->
        Exec.sandbox(e, v)

      {:approval_policy, v}, e ->
        Exec.approval_policy(e, v)

      {:full_auto, true}, e ->
        Exec.full_auto(e)

      {:full_auto, false}, e ->
        e

      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        Exec.dangerously_bypass_approvals_and_sandbox(e)

      {:dangerously_bypass_approvals_and_sandbox, false}, e ->
        e

      {:cd, v}, e ->
        Exec.cd(e, v)

      {:skip_git_repo_check, true}, e ->
        Exec.skip_git_repo_check(e)

      {:skip_git_repo_check, false}, e ->
        e

      {:search, true}, e ->
        Exec.search(e)

      {:search, false}, e ->
        e

      {:search, mode}, e when is_atom(mode) ->
        Exec.search(e, mode)

      {:ephemeral, true}, e ->
        Exec.ephemeral(e)

      {:ephemeral, false}, e ->
        e

      {:json, true}, e ->
        Exec.json(e)

      {:json, false}, e ->
        e

      {:output_schema, v}, e ->
        Exec.output_schema(e, v)

      {:output_last_message, v}, e ->
        Exec.output_last_message(e, v)

      _other, e ->
        e
    end)
  end
end
