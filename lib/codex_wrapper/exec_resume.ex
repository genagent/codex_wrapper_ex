defmodule CodexWrapper.ExecResume do
  @moduledoc """
  ExecResume command -- resume an existing session non-interactively.

  Wraps `codex exec resume [session_id] [prompt]` with the full set of CLI flags.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

      # Resume the most recent session
      exec = CodexWrapper.ExecResume.new()
        |> CodexWrapper.ExecResume.last()
        |> CodexWrapper.ExecResume.prompt("continue with tests")

      {:ok, result} = CodexWrapper.ExecResume.execute(exec, config)

      # Resume a specific session by ID
      exec = CodexWrapper.ExecResume.new()
        |> CodexWrapper.ExecResume.session_id("abc-123")
        |> CodexWrapper.ExecResume.prompt("add error handling")

      {:ok, result} = CodexWrapper.ExecResume.execute(exec, config)
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config, JsonLineEvent, Result}

  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          prompt: String.t() | nil,
          last: boolean(),
          all: boolean(),
          model: String.t() | nil,
          sandbox: sandbox_mode() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          skip_git_repo_check: boolean(),
          ephemeral: boolean(),
          json: boolean(),
          output_last_message: String.t() | nil,
          images: [String.t()],
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()]
        }

  defstruct [
    :session_id,
    :prompt,
    :model,
    :output_last_message,
    :sandbox,
    last: false,
    all: false,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    skip_git_repo_check: false,
    ephemeral: false,
    json: false,
    images: [],
    config_overrides: [],
    enabled_features: [],
    disabled_features: []
  ]

  # --- Constructor ---

  @doc """
  Create a new exec resume command.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- Builder functions ---

  @doc "Set the session ID to resume."
  @spec session_id(t(), String.t()) :: t()
  def session_id(%__MODULE__{} = e, id), do: %{e | session_id: id}

  @doc "Set the continuation prompt."
  @spec prompt(t(), String.t()) :: t()
  def prompt(%__MODULE__{} = e, prompt), do: %{e | prompt: prompt}

  @doc "Resume the most recent session."
  @spec last(t()) :: t()
  def last(%__MODULE__{} = e), do: %{e | last: true}

  @doc "Show all sessions (disables cwd filtering)."
  @spec all(t()) :: t()
  def all(%__MODULE__{} = e), do: %{e | all: true}

  @doc "Set the model."
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = e, model), do: %{e | model: model}

  @doc "Set the sandbox mode."
  @spec sandbox(t(), sandbox_mode()) :: t()
  def sandbox(%__MODULE__{} = e, mode), do: %{e | sandbox: mode}

  @doc """
  Enable full-auto mode.

  Deprecated upstream. Emits `--sandbox workspace-write`, which is what
  the Codex CLI now tells you to use in place of `--full-auto`. An
  explicit `sandbox/2` call is more specific and wins over this.
  """
  @spec full_auto(t()) :: t()
  def full_auto(%__MODULE__{} = e), do: %{e | full_auto: true}

  @doc "Bypass all approvals and sandbox. Use with extreme caution."
  @spec dangerously_bypass_approvals_and_sandbox(t()) :: t()
  def dangerously_bypass_approvals_and_sandbox(%__MODULE__{} = e),
    do: %{e | dangerously_bypass_approvals_and_sandbox: true}

  @doc "Skip the git repo check."
  @spec skip_git_repo_check(t()) :: t()
  def skip_git_repo_check(%__MODULE__{} = e), do: %{e | skip_git_repo_check: true}

  @doc "Enable ephemeral mode (no session persistence)."
  @spec ephemeral(t()) :: t()
  def ephemeral(%__MODULE__{} = e), do: %{e | ephemeral: true}

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

  Forces `--json` on the command, runs synchronously, then parses
  each NDJSON line from stdout.
  """
  @spec execute_json(t(), Config.t()) :: {:ok, [JsonLineEvent.t()]} | {:error, term()}
  def execute_json(%__MODULE__{} = exec, %Config{} = config) do
    exec = %{exec | json: true}

    case execute(exec, config) do
      {:ok, result} -> {:ok, JsonLineEvent.parse_lines(result.stdout)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Execute the command and return a lazy `Stream` of `%JsonLineEvent{}`.

  Forces `--json` on the command. Uses a Port with `:line` mode.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = exec, %Config{} = config) do
    exec = %{exec | json: true}
    args = Config.base_args(config) ++ args(exec)
    shell_args = Command.shell_cmd_args(config.binary, args)

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, shell_args}] ++
        port_env_opts(config) ++
        port_cd_opts(config)

    Stream.resource(
      fn ->
        Port.open({:spawn_executable, "/bin/sh"}, port_opts)
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
    ["exec", "resume"]
    |> add_list("-c", e.config_overrides)
    |> add_list("--enable", e.enabled_features)
    |> add_list("--disable", e.disabled_features)
    |> add_bool("--last", e.last)
    |> add_bool("--all", e.all)
    |> add_list("--image", e.images)
    |> add_opt("--model", e.model)
    |> add_opt("--sandbox", format_sandbox(effective_sandbox(e)))
    |> add_bool(
      "--dangerously-bypass-approvals-and-sandbox",
      e.dangerously_bypass_approvals_and_sandbox
    )
    |> add_bool("--skip-git-repo-check", e.skip_git_repo_check)
    |> add_bool("--ephemeral", e.ephemeral)
    |> add_bool("--json", e.json)
    |> add_opt("--output-last-message", e.output_last_message)
    |> add_opt_flag(e.session_id)
    |> add_opt_flag(e.prompt)
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

  defp add_opt_flag(args, nil), do: args
  defp add_opt_flag(args, value), do: args ++ [value]
  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

  # --- Port helpers ---

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]

  # `--full-auto` is deprecated upstream ("use --sandbox workspace-write"),
  # so translate it instead of emitting it. An explicit sandbox/2 call is
  # the more specific instruction and wins.
  defp effective_sandbox(%__MODULE__{sandbox: nil, full_auto: true}), do: :workspace_write
  defp effective_sandbox(%__MODULE__{sandbox: mode}), do: mode

  defp format_sandbox(nil), do: nil
  defp format_sandbox(:read_only), do: "read-only"
  defp format_sandbox(:workspace_write), do: "workspace-write"
  defp format_sandbox(:danger_full_access), do: "danger-full-access"
end
