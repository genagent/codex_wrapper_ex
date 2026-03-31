defmodule CodexWrapper.Exec do
  @moduledoc """
  Exec command — the primary interface for non-interactive prompts.

  Wraps `codex exec <prompt>` with the full set of CLI flags.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

      # Build an exec command
      exec = CodexWrapper.Exec.new("Fix the failing test")
        |> CodexWrapper.Exec.model("o3")
        |> CodexWrapper.Exec.sandbox(:workspace_write)
        |> CodexWrapper.Exec.ephemeral()

      # Execute (returns result)
      {:ok, result} = CodexWrapper.Exec.execute(exec, config)
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config, JsonLineEvent, Result}

  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access
  @type approval_policy :: :untrusted | :on_failure | :on_request | :never

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: String.t() | nil,
          sandbox: sandbox_mode() | nil,
          approval_policy: approval_policy() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          cd: String.t() | nil,
          skip_git_repo_check: boolean(),
          add_dirs: [String.t()],
          search: boolean(),
          ephemeral: boolean(),
          output_schema: String.t() | nil,
          json: boolean(),
          output_last_message: String.t() | nil,
          images: [String.t()],
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()]
        }

  defstruct [
    :prompt,
    :model,
    :sandbox,
    :approval_policy,
    :cd,
    :output_schema,
    :output_last_message,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    skip_git_repo_check: false,
    search: false,
    ephemeral: false,
    json: false,
    add_dirs: [],
    images: [],
    config_overrides: [],
    enabled_features: [],
    disabled_features: []
  ]

  # --- Constructor ---

  @doc """
  Create a new exec command with the given prompt.
  """
  @spec new(String.t()) :: t()
  def new(prompt) when is_binary(prompt) do
    %__MODULE__{prompt: prompt}
  end

  # --- Builder functions ---

  @doc "Set the model."
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = e, model), do: %{e | model: model}

  @doc "Set the sandbox mode."
  @spec sandbox(t(), sandbox_mode()) :: t()
  def sandbox(%__MODULE__{} = e, mode), do: %{e | sandbox: mode}

  @doc "Set the approval policy."
  @spec approval_policy(t(), approval_policy()) :: t()
  def approval_policy(%__MODULE__{} = e, policy), do: %{e | approval_policy: policy}

  @doc "Enable full-auto mode."
  @spec full_auto(t()) :: t()
  def full_auto(%__MODULE__{} = e), do: %{e | full_auto: true}

  @doc "Bypass all approvals and sandbox. Use with extreme caution."
  @spec dangerously_bypass_approvals_and_sandbox(t()) :: t()
  def dangerously_bypass_approvals_and_sandbox(%__MODULE__{} = e),
    do: %{e | dangerously_bypass_approvals_and_sandbox: true}

  @doc "Set the working directory for the codex subprocess."
  @spec cd(t(), String.t()) :: t()
  def cd(%__MODULE__{} = e, dir), do: %{e | cd: dir}

  @doc "Skip the git repo check."
  @spec skip_git_repo_check(t()) :: t()
  def skip_git_repo_check(%__MODULE__{} = e), do: %{e | skip_git_repo_check: true}

  @doc "Add a directory for context."
  @spec add_dir(t(), String.t()) :: t()
  def add_dir(%__MODULE__{} = e, dir), do: %{e | add_dirs: e.add_dirs ++ [dir]}

  @doc "Enable live web search."
  @spec search(t()) :: t()
  def search(%__MODULE__{} = e), do: %{e | search: true}

  @doc "Enable ephemeral mode (no session persistence)."
  @spec ephemeral(t()) :: t()
  def ephemeral(%__MODULE__{} = e), do: %{e | ephemeral: true}

  @doc "Set the output schema path."
  @spec output_schema(t(), String.t()) :: t()
  def output_schema(%__MODULE__{} = e, path), do: %{e | output_schema: path}

  @doc "Enable JSON output."
  @spec json(t()) :: t()
  def json(%__MODULE__{} = e), do: %{e | json: true}

  @doc "Set the output-last-message path."
  @spec output_last_message(t(), String.t()) :: t()
  def output_last_message(%__MODULE__{} = e, path), do: %{e | output_last_message: path}

  @doc "Add an image path."
  @spec image(t(), String.t()) :: t()
  def image(%__MODULE__{} = e, path), do: %{e | images: e.images ++ [path]}

  @doc "Add a config override (key=value)."
  @spec config(t(), String.t()) :: t()
  def config(%__MODULE__{} = e, kv), do: %{e | config_overrides: e.config_overrides ++ [kv]}

  @doc "Enable a feature."
  @spec enable(t(), String.t()) :: t()
  def enable(%__MODULE__{} = e, feature),
    do: %{e | enabled_features: e.enabled_features ++ [feature]}

  @doc "Disable a feature."
  @spec disable(t(), String.t()) :: t()
  def disable(%__MODULE__{} = e, feature),
    do: %{e | disabled_features: e.disabled_features ++ [feature]}

  # --- Execution ---

  @doc """
  Execute the command synchronously, returning a parsed `%Result{}`.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, term()}
  def execute(%__MODULE__{} = exec, %Config{} = config) do
    Command.run(__MODULE__, exec, config)
  end

  @doc """
  Execute the command with `--json` and return a list of parsed `%JsonLineEvent{}`.

  Forces `--json` on the exec command, runs synchronously, then parses
  each NDJSON line from stdout.
  """
  @spec execute_json(t(), Config.t()) :: {:ok, [JsonLineEvent.t()]} | {:error, term()}
  def execute_json(%__MODULE__{} = exec, %Config{} = config) do
    exec = %{exec | json: true}

    case execute(exec, config) do
      {:ok, result} ->
        events =
          result.stdout
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "{"))
          |> Enum.flat_map(fn line ->
            case JsonLineEvent.parse(line) do
              {:ok, event} -> [event]
              {:error, _} -> []
            end
          end)

        {:ok, events}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Execute the command and return a lazy `Stream` of `%JsonLineEvent{}`.

  Uses a Port with `:line` mode to read NDJSON output line-by-line.
  The port is opened when the stream is consumed and closed when
  the stream terminates.

  Forces `--json` on the exec command.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = exec, %Config{} = config) do
    exec = %{exec | json: true}
    args = Config.base_args(config) ++ args(exec)

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, args}] ++
        port_env_opts(config) ++
        port_cd_opts(config)

    Stream.resource(
      fn ->
        Port.open({:spawn_executable, config.binary}, port_opts)
      end,
      fn port ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            case JsonLineEvent.parse(line) do
              {:ok, event} -> {[event], port}
              {:error, _} -> {[], port}
            end

          {^port, {:data, {:noeol, _partial}}} ->
            {[], port}

          {^port, {:exit_status, _code}} ->
            {:halt, port}
        after
          300_000 -> {:halt, port}
        end
      end,
      fn port ->
        send(port, {self(), :close})

        receive do
          {^port, :closed} -> :ok
        after
          5_000 -> :ok
        end
      end
    )
  end

  # --- Command behaviour ---

  @impl Command
  def args(%__MODULE__{} = e) do
    ["exec"]
    |> add_list("-c", e.config_overrides)
    |> add_list("--enable", e.enabled_features)
    |> add_list("--disable", e.disabled_features)
    |> add_list("--image", e.images)
    |> add_opt("--model", e.model)
    |> add_opt("--sandbox", format_sandbox(e.sandbox))
    |> add_opt("--ask-for-approval", format_approval_policy(e.approval_policy))
    |> add_bool("--full-auto", e.full_auto)
    |> add_bool("--dangerously-bypass-approvals-and-sandbox",
         e.dangerously_bypass_approvals_and_sandbox)
    |> add_opt("--cd", e.cd)
    |> add_bool("--skip-git-repo-check", e.skip_git_repo_check)
    |> add_list("--add-dir", e.add_dirs)
    |> add_bool("--search", e.search)
    |> add_bool("--ephemeral", e.ephemeral)
    |> add_opt("--output-schema", e.output_schema)
    |> add_bool("--json", e.json)
    |> add_opt("--output-last-message", e.output_last_message)
    |> add_flag(e.prompt)
  end

  @impl Command
  def parse_output(stdout, exit_code) do
    result = Result.from_cmd({stdout, exit_code})

    if result.success do
      {:ok, result}
    else
      {:ok, result}
    end
  end

  # --- Arg helpers ---

  defp add_flag(args, value), do: args ++ [value]
  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

  # --- Format helpers ---

  defp format_sandbox(nil), do: nil
  defp format_sandbox(:read_only), do: "read-only"
  defp format_sandbox(:workspace_write), do: "workspace-write"
  defp format_sandbox(:danger_full_access), do: "danger-full-access"

  defp format_approval_policy(nil), do: nil
  defp format_approval_policy(:untrusted), do: "untrusted"
  defp format_approval_policy(:on_failure), do: "on-failure"
  defp format_approval_policy(:on_request), do: "on-request"
  defp format_approval_policy(:never), do: "never"

  # --- Port helpers ---

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
