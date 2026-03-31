defmodule CodexWrapper.Commands.Fork do
  @moduledoc """
  Fork command — fork an existing session to try a different approach.

  Wraps `codex fork [session-id] [prompt]` with the full set of CLI flags.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

      # Fork the most recent session
      fork = CodexWrapper.Commands.Fork.new()
        |> CodexWrapper.Commands.Fork.last()
        |> CodexWrapper.Commands.Fork.prompt("take a different approach")

      {:ok, result} = CodexWrapper.Commands.Fork.execute(fork, config)

      # Fork a specific session by ID
      fork = CodexWrapper.Commands.Fork.new()
        |> CodexWrapper.Commands.Fork.session_id("abc-123")
        |> CodexWrapper.Commands.Fork.model("o3")

      {:ok, result} = CodexWrapper.Commands.Fork.execute(fork, config)
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config, Result}

  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access
  @type approval_policy :: :untrusted | :on_failure | :on_request | :never

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          prompt: String.t() | nil,
          last: boolean(),
          all: boolean(),
          model: String.t() | nil,
          sandbox: sandbox_mode() | nil,
          approval_policy: approval_policy() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          cd: String.t() | nil,
          search: boolean(),
          add_dirs: [String.t()],
          images: [String.t()],
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()]
        }

  defstruct [
    :session_id,
    :prompt,
    :model,
    :sandbox,
    :approval_policy,
    :cd,
    last: false,
    all: false,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    search: false,
    add_dirs: [],
    images: [],
    config_overrides: [],
    enabled_features: [],
    disabled_features: []
  ]

  # --- Constructor ---

  @doc """
  Create a new fork command.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- Builder functions ---

  @doc "Set the session ID to fork."
  @spec session_id(t(), String.t()) :: t()
  def session_id(%__MODULE__{} = f, id), do: %{f | session_id: id}

  @doc "Set the prompt for the forked session."
  @spec prompt(t(), String.t()) :: t()
  def prompt(%__MODULE__{} = f, prompt), do: %{f | prompt: prompt}

  @doc "Fork the most recent session."
  @spec last(t()) :: t()
  def last(%__MODULE__{} = f), do: %{f | last: true}

  @doc "Show all sessions (disables cwd filtering)."
  @spec all(t()) :: t()
  def all(%__MODULE__{} = f), do: %{f | all: true}

  @doc "Set the model."
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = f, model), do: %{f | model: model}

  @doc "Set the sandbox mode."
  @spec sandbox(t(), sandbox_mode()) :: t()
  def sandbox(%__MODULE__{} = f, mode), do: %{f | sandbox: mode}

  @doc "Set the approval policy."
  @spec approval_policy(t(), approval_policy()) :: t()
  def approval_policy(%__MODULE__{} = f, policy), do: %{f | approval_policy: policy}

  @doc "Enable full-auto mode."
  @spec full_auto(t()) :: t()
  def full_auto(%__MODULE__{} = f), do: %{f | full_auto: true}

  @doc "Bypass all approvals and sandbox. Use with extreme caution."
  @spec dangerously_bypass_approvals_and_sandbox(t()) :: t()
  def dangerously_bypass_approvals_and_sandbox(%__MODULE__{} = f),
    do: %{f | dangerously_bypass_approvals_and_sandbox: true}

  @doc "Set the working directory for the codex subprocess."
  @spec cd(t(), String.t()) :: t()
  def cd(%__MODULE__{} = f, dir), do: %{f | cd: dir}

  @doc "Enable live web search."
  @spec search(t()) :: t()
  def search(%__MODULE__{} = f), do: %{f | search: true}

  @doc "Add a directory for context."
  @spec add_dir(t(), String.t()) :: t()
  def add_dir(%__MODULE__{} = f, dir), do: %{f | add_dirs: f.add_dirs ++ [dir]}

  @doc "Add an image path."
  @spec image(t(), String.t()) :: t()
  def image(%__MODULE__{} = f, path), do: %{f | images: f.images ++ [path]}

  @doc "Add a config override (key=value)."
  @spec config(t(), String.t()) :: t()
  def config(%__MODULE__{} = f, kv), do: %{f | config_overrides: f.config_overrides ++ [kv]}

  @doc "Enable a feature."
  @spec enable(t(), String.t()) :: t()
  def enable(%__MODULE__{} = f, feature),
    do: %{f | enabled_features: f.enabled_features ++ [feature]}

  @doc "Disable a feature."
  @spec disable(t(), String.t()) :: t()
  def disable(%__MODULE__{} = f, feature),
    do: %{f | disabled_features: f.disabled_features ++ [feature]}

  # --- Execution ---

  @doc """
  Execute the fork command synchronously, returning a parsed `%Result{}`.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, term()}
  def execute(%__MODULE__{} = fork, %Config{} = config) do
    Command.run(__MODULE__, fork, config)
  end

  # --- Command behaviour ---

  @impl Command
  def args(%__MODULE__{} = f) do
    ["fork"]
    |> add_list("-c", f.config_overrides)
    |> add_list("--enable", f.enabled_features)
    |> add_list("--disable", f.disabled_features)
    |> add_bool("--last", f.last)
    |> add_bool("--all", f.all)
    |> add_list("--image", f.images)
    |> add_opt("--model", f.model)
    |> add_opt("--sandbox", format_sandbox(f.sandbox))
    |> add_opt("--ask-for-approval", format_approval_policy(f.approval_policy))
    |> add_bool("--full-auto", f.full_auto)
    |> add_bool(
      "--dangerously-bypass-approvals-and-sandbox",
      f.dangerously_bypass_approvals_and_sandbox
    )
    |> add_opt("--cd", f.cd)
    |> add_bool("--search", f.search)
    |> add_list("--add-dir", f.add_dirs)
    |> add_opt_flag(f.session_id)
    |> add_opt_flag(f.prompt)
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
end
