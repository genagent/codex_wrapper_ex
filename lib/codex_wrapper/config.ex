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
          env: [{String.t(), String.t() | false}],
          timeout: pos_integer() | nil,
          idle_timeout_ms: pos_integer() | nil,
          verbose: boolean(),
          runner: module() | atom() | nil,
          runner_explicit: boolean() | nil,
          runner_options: keyword() | nil,
          runner_default_timeout_ms: pos_integer() | nil
        }

  defstruct [
    :binary,
    :working_dir,
    :timeout,
    :idle_timeout_ms,
    :runner,
    :runner_explicit,
    :runner_options,
    :runner_default_timeout_ms,
    env: [],
    verbose: false
  ]

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:binary` - Literal executable path or name on `PATH` (default: auto-discover).
      Shell commands and unexpanded `~` or environment-variable paths are not supported.
    * `:working_dir` - Working directory for the subprocess
    * `:env` - List of `{name, value}` environment variable tuples (a map is
      also accepted). A string value sets the variable for the child; `nil` or
      `false` removes an inherited variable, on every runner path. Names must
      be nonempty and contain no `=`; names and values must contain no NUL.
      Invalid entries raise `ArgumentError`. `nil` is stored as `false`.
    * `:timeout` - Whole-command timeout in milliseconds
    * `:idle_timeout_ms` - Maximum gap between output frames while streaming
      or using evidenced one-shot execution
      (default: 300,000 ms)
    * `:runner` - Runner module or `:task` / `:forcola` shorthand. Application
      defaults are snapshotted at construction, only when this field is absent.
      An explicitly selected runner must implement `stream_lines/4` for streaming;
      otherwise consumption raises `ArgumentError` before spawning. Implicit
      application/default selection retains the legacy Port fallback with a warning.
      Direct structs with a non-nil runner are treated as explicit selections.
      `:runner_explicit` is internal selection provenance set by `new/1`.
    * `:runner_options` - Validated one-shot transport options. An explicit `[]`
      overrides application defaults. See `runner_options/1` for supported keys.
    * `:verbose` - Compatibility option. Only `false` is supported; `true` raises
      `ArgumentError` before the CLI is launched, because the Codex CLI does not
      define a `--verbose` flag
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    validate_verbose!(verbose)

    runner =
      opts
      |> Keyword.get_lazy(:runner, &CodexWrapper.Runner.impl/0)
      |> CodexWrapper.Runner.resolve()

    %__MODULE__{
      binary: opts[:binary] || find_binary(),
      working_dir: opts[:working_dir],
      env: validate_env!(opts[:env] || []),
      timeout: opts[:timeout],
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 300_000),
      verbose: verbose,
      runner: runner,
      runner_explicit: Keyword.has_key?(opts, :runner),
      runner_default_timeout_ms:
        Application.get_env(:codex_wrapper, :forcola_default_timeout_ms, 300_000),
      runner_options:
        validate_runner_options!(
          Keyword.get_lazy(opts, :runner_options, fn ->
            Application.get_env(:codex_wrapper, :runner_options, [])
          end)
        )
    }
  end

  @doc false
  @spec validate_env!(Enumerable.t()) :: [{String.t(), String.t() | false}]
  def validate_env!(env) when is_list(env) or is_map(env) do
    Enum.map(env, fn
      {name, value} ->
        {env_name!(name), env_value!(name, value)}

      other ->
        raise ArgumentError, "env entries must be {name, value} tuples, got: #{inspect(other)}"
    end)
  end

  def validate_env!(env),
    do: raise(ArgumentError, "env must be a list of {name, value} tuples, got: #{inspect(env)}")

  defp env_name!(name) when is_list(name), do: env_name!(List.to_string(name))

  defp env_name!(name) when is_binary(name) and name != "" do
    if String.contains?(name, ["=", <<0>>]),
      do: raise(ArgumentError, "env name must not contain = or NUL: #{inspect(name)}"),
      else: name
  end

  defp env_name!(name),
    do: raise(ArgumentError, "env name must be a nonempty string, got: #{inspect(name)}")

  defp env_value!(_name, value) when value in [nil, false], do: false
  defp env_value!(name, value) when is_list(value), do: env_value!(name, List.to_string(value))

  defp env_value!(name, value) when is_binary(value) do
    if String.contains?(value, <<0>>),
      do: raise(ArgumentError, "env value for #{inspect(name)} must not contain NUL"),
      else: value
  end

  defp env_value!(name, value) do
    raise ArgumentError,
          "env value for #{inspect(name)} must be a string, nil or false, got: #{inspect(value)}"
  end

  @doc """
  Return validated immutable transport options. Direct structs with `nil` fields
  retain legacy application-default lookup; `new/1` snapshots those defaults.

  Supported keys: `:shim_path` (absolute path), `:env_mode` (`:inherit` or
  `:replace`), `:timeout_ms`, `:idle_timeout_ms`, `:max_output_bytes`,
  `:kill_grace_ms`, and the paired `:interrupt_signal` (`:int`) and
  `:interrupt_grace_ms`. Limits are positive 32-bit integers; kill grace may
  be zero. These requirements need a runner implementing `validate_options/1`.
  `:timeout_ms` supplies the runner default; config `:timeout` takes precedence.
  New requirements are refused by unsupported runners before spawning. These
  options apply to one-shot execution; streams reject nonempty options before
  spawning rather than silently losing requirements.
  """
  @spec runner_options(t()) :: keyword()
  def runner_options(%__MODULE__{runner_options: nil}),
    do: validate_runner_options!(Application.get_env(:codex_wrapper, :runner_options, []))

  def runner_options(%__MODULE__{runner_options: opts}), do: validate_runner_options!(opts)

  @doc false
  def validate_runner_options!(opts) do
    unless Keyword.keyword?(opts) and
             length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      raise ArgumentError, "runner_options must be a keyword list without duplicate keys"
    end

    Enum.each(opts, fn {key, value} ->
      unless valid_runner_option?(key, value),
        do: raise(ArgumentError, "invalid runner option #{inspect(key)}")
    end)

    if Keyword.has_key?(opts, :interrupt_signal) != Keyword.has_key?(opts, :interrupt_grace_ms),
      do:
        raise(ArgumentError, "interrupt_signal and interrupt_grace_ms must be supplied together")

    opts
  end

  defp valid_runner_option?(:shim_path, value) do
    is_binary(value) and Path.type(value) == :absolute and not String.contains?(value, <<0>>)
  end

  defp valid_runner_option?(:env_mode, value), do: value in [:inherit, :replace]
  defp valid_runner_option?(:interrupt_signal, value), do: value == :int

  defp valid_runner_option?(:kill_grace_ms, value),
    do: is_integer(value) and value >= 0 and value <= 4_294_967_295

  defp valid_runner_option?(key, value)
       when key in [:timeout_ms, :idle_timeout_ms, :max_output_bytes, :interrupt_grace_ms],
       do: is_integer(value) and value > 0 and value <= 4_294_967_295

  defp valid_runner_option?(_, _), do: false

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

  @doc false
  @spec execution_opts(t()) :: keyword()
  def execution_opts(config), do: Keyword.merge(cmd_opts(config), runner_options(config))

  @doc """
  Build the runner options for a streaming run.

  Same shape as `cmd_opts/1` but with `stderr_to_stdout: false`: the
  streaming paths parse NDJSON off stdout, and merging stderr into it
  would put unparseable lines in the stream. Stderr is left to flow to
  the parent's stderr.
  """
  @spec stream_opts(t()) :: keyword()
  def stream_opts(%__MODULE__{} = config) do
    if runner_options(config) != [],
      do: raise(ArgumentError, "runner_options are supported only by one-shot execution")

    config
    |> cmd_opts()
    |> Keyword.put(:stderr_to_stdout, false)
    |> Keyword.put(:idle_timeout_ms, config.idle_timeout_ms)
  end
end
