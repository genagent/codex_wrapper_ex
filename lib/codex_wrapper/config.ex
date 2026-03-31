defmodule CodexWrapper.Config do
  @moduledoc """
  Shared client configuration for the Codex CLI.

  Holds binary path, working directory, environment variables, and default
  options that apply across all commands.

  ## Usage

      config = CodexWrapper.Config.new()
      config = CodexWrapper.Config.new(working_dir: "/path/to/project")
  """

  @type t :: %__MODULE__{
          binary: String.t(),
          working_dir: String.t() | nil,
          env: [{String.t(), String.t()}],
          timeout: pos_integer() | nil,
          verbose: boolean()
        }

  defstruct [
    :binary,
    :working_dir,
    :timeout,
    env: [],
    verbose: false
  ]

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:binary` - Path to the codex binary (default: auto-discover)
    * `:working_dir` - Working directory for the subprocess
    * `:env` - List of `{key, value}` environment variable tuples
    * `:timeout` - Command timeout in milliseconds
    * `:verbose` - Enable verbose output
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      binary: opts[:binary] || find_binary(),
      working_dir: opts[:working_dir],
      env: opts[:env] || [],
      timeout: opts[:timeout],
      verbose: Keyword.get(opts, :verbose, false)
    }
  end

  @doc """
  Find the codex binary path.

  Checks in order:
  1. `CODEX_CLI` environment variable
  2. System PATH
  """
  @spec find_binary() :: String.t()
  def find_binary do
    case System.get_env("CODEX_CLI") do
      nil -> System.find_executable("codex") || "codex"
      path -> path
    end
  end

  @doc """
  Build the base command args from config (global flags).
  """
  @spec base_args(t()) :: [String.t()]
  def base_args(%__MODULE__{} = config) do
    if config.verbose, do: ["--verbose"], else: []
  end

  @doc """
  Build the cmd options (working dir, env) for `System.cmd`.
  """
  @spec cmd_opts(t()) :: keyword()
  def cmd_opts(%__MODULE__{} = config) do
    opts = [stderr_to_stdout: true]
    opts = if config.working_dir, do: [{:cd, config.working_dir} | opts], else: opts
    opts = if config.env != [], do: [{:env, config.env} | opts], else: opts
    opts
  end
end
