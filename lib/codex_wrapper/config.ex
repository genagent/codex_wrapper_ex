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
          idle_timeout_ms: pos_integer() | nil,
          verbose: boolean()
        }

  defstruct [
    :binary,
    :working_dir,
    :timeout,
    :idle_timeout_ms,
    env: [],
    verbose: false
  ]

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:binary` - Literal executable path or name on `PATH` (default: auto-discover).
      Shell commands and unexpanded `~` or environment-variable paths are not supported.
    * `:working_dir` - Working directory for the subprocess
    * `:env` - List of `{key, value}` environment variable tuples
    * `:timeout` - Whole-command timeout in milliseconds for streaming runs
    * `:idle_timeout_ms` - Maximum gap between output frames while streaming
      (default: 300,000 ms)
    * `:verbose` - Compatibility option. Only `false` is supported; `true` raises
      `ArgumentError` before the CLI is launched, because the Codex CLI does not
      define a `--verbose` flag
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    validate_verbose!(verbose)

    %__MODULE__{
      binary: opts[:binary] || find_binary(),
      working_dir: opts[:working_dir],
      env: opts[:env] || [],
      timeout: opts[:timeout],
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 300_000),
      verbose: verbose
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

  Currently always empty. Raises `ArgumentError` if `verbose: true` was set
  on a directly constructed or updated struct.
  """
  @spec base_args(t()) :: [String.t()]
  def base_args(%__MODULE__{} = config) do
    validate_verbose!(config.verbose)
    []
  end

  defp validate_verbose!(verbose) when verbose in [false, nil], do: :ok

  defp validate_verbose!(_verbose) do
    raise ArgumentError,
          "verbose: true is unsupported: the Codex CLI does not define --verbose"
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

  @doc """
  Build the runner options for a streaming run.

  Same shape as `cmd_opts/1` but with `stderr_to_stdout: false`: the
  streaming paths parse NDJSON off stdout, and merging stderr into it
  would put unparseable lines in the stream. Stderr is left to flow to
  the parent's stderr.
  """
  @spec stream_opts(t()) :: keyword()
  def stream_opts(%__MODULE__{} = config) do
    config
    |> cmd_opts()
    |> Keyword.put(:stderr_to_stdout, false)
    |> Keyword.put(:idle_timeout_ms, config.idle_timeout_ms)
  end
end
