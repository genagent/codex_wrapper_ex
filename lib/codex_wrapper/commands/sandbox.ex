defmodule CodexWrapper.Commands.Sandbox do
  @moduledoc """
  Sandbox command -- run a command inside the Codex sandbox.

  Wraps `codex sandbox [OPTIONS] [COMMAND]...`.

  The platform is no longer part of the invocation. Codex used to take it
  as a subcommand (`codex sandbox macos -- ls`); as of codex-cli 0.14x the
  command is flat and the platform is inferred from the host, so
  `new/1` takes the command directly. See #56.

  ## Usage

      config = CodexWrapper.Config.new()

      sandbox =
        CodexWrapper.Commands.Sandbox.new("ls")
        |> CodexWrapper.Commands.Sandbox.arg("-la")

      {:ok, output} = CodexWrapper.Commands.Sandbox.execute(sandbox, config)

  ## Sandbox state

  The sandbox-state options configure what the sandboxed process can
  reach. They are independent of the `:permission_profile`, which selects
  a named profile from the Codex config:

      CodexWrapper.Commands.Sandbox.new("pytest")
      |> CodexWrapper.Commands.Sandbox.permission_profile("ci")
      |> CodexWrapper.Commands.Sandbox.sandbox_state_readable_root("/usr/share")
      |> CodexWrapper.Commands.Sandbox.sandbox_state_disable_network()
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config}

  @type t :: %__MODULE__{
          command: String.t(),
          command_args: [String.t()],
          permission_profile: String.t() | nil,
          sandbox_state_json: String.t() | nil,
          sandbox_state_readable_roots: [String.t()],
          sandbox_state_disable_network: boolean(),
          cd: String.t() | nil
        }

  defstruct [
    :command,
    :permission_profile,
    :sandbox_state_json,
    :cd,
    command_args: [],
    sandbox_state_readable_roots: [],
    sandbox_state_disable_network: false
  ]

  # --- Constructor ---

  @doc """
  Create a sandbox command for the given command.
  """
  @spec new(String.t()) :: t()
  def new(command) when is_binary(command) do
    %__MODULE__{command: command}
  end

  @doc false
  # `codex sandbox <platform>` was removed upstream. Raise rather than
  # ignore the platform, so callers on the old API get a migration
  # message instead of a silently different invocation.
  @spec new(atom(), String.t()) :: no_return()
  def new(platform, command) when is_atom(platform) and is_binary(command) do
    raise ArgumentError, """
    CodexWrapper.Commands.Sandbox.new/2 took a platform atom, which the Codex CLI no longer accepts.

    Use new/1 instead; the platform is inferred from the host:

        CodexWrapper.Commands.Sandbox.new(#{inspect(command)})
    """
  end

  # --- Builder functions ---

  @doc "Add an argument to the sandboxed command."
  @spec arg(t(), String.t()) :: t()
  def arg(%__MODULE__{} = s, arg), do: %{s | command_args: s.command_args ++ [arg]}

  @doc "Add multiple arguments to the sandboxed command."
  @spec args(t(), [String.t()]) :: t()
  def args(%__MODULE__{} = s, args) when is_list(args),
    do: %{s | command_args: s.command_args ++ args}

  @doc "Select a named permission profile (`--permission-profile`)."
  @spec permission_profile(t(), String.t()) :: t()
  def permission_profile(%__MODULE__{} = s, profile) when is_binary(profile),
    do: %{s | permission_profile: profile}

  @doc "Path to a sandbox state JSON file (`--sandbox-state-json`)."
  @spec sandbox_state_json(t(), String.t()) :: t()
  def sandbox_state_json(%__MODULE__{} = s, path) when is_binary(path),
    do: %{s | sandbox_state_json: path}

  @doc """
  Grant read access to a root (`--sandbox-state-readable-root`).

  Accumulates: call once per root.
  """
  @spec sandbox_state_readable_root(t(), String.t()) :: t()
  def sandbox_state_readable_root(%__MODULE__{} = s, root) when is_binary(root),
    do: %{s | sandbox_state_readable_roots: s.sandbox_state_readable_roots ++ [root]}

  @doc "Disable network access inside the sandbox (`--sandbox-state-disable-network`)."
  @spec sandbox_state_disable_network(t()) :: t()
  def sandbox_state_disable_network(%__MODULE__{} = s),
    do: %{s | sandbox_state_disable_network: true}

  @doc """
  Working directory for the sandboxed command (`--cd`).

  Distinct from `Config`'s `:working_dir`, which sets the subprocess cwd.
  """
  @spec cd(t(), String.t()) :: t()
  def cd(%__MODULE__{} = s, dir) when is_binary(dir), do: %{s | cd: dir}

  # --- Execution ---

  @doc """
  Execute the sandbox command synchronously.
  """
  @spec execute(t(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(%__MODULE__{} = sandbox, %Config{} = config) do
    Command.run(__MODULE__, sandbox, config)
  end

  # --- Arg building ---

  @doc """
  Build the argument list for this command.
  """
  @spec build_args(t()) :: [String.t()]
  def build_args(%__MODULE__{} = s), do: args(s)

  @impl true
  def args(%__MODULE__{} = s) do
    # `--` separates codex's own options from the sandboxed command, so a
    # command with leading dashes is not parsed as a codex flag.
    ["sandbox"]
    |> add_opt("--permission-profile", s.permission_profile)
    |> add_opt("--sandbox-state-json", s.sandbox_state_json)
    |> add_list("--sandbox-state-readable-root", s.sandbox_state_readable_roots)
    |> add_bool("--sandbox-state-disable-network", s.sandbox_state_disable_network)
    |> add_opt("--cd", s.cd)
    |> Kernel.++(["--", s.command])
    |> Kernel.++(s.command_args)
  end

  @impl true
  def parse_output(stdout, 0), do: {:ok, String.trim(stdout)}
  def parse_output(stdout, exit_code), do: {:error, {:exit, exit_code, stdout}}

  # --- Arg helpers ---

  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])
end
