defmodule CodexWrapper.Commands.Queue do
  @moduledoc """
  Queue a message for an existing session.

  Wraps `codex queue --thread <thread> --message <text>`. `thread` is a
  session id (UUID) or an exact session name.

      config = CodexWrapper.Config.new()
      {:ok, _output} = CodexWrapper.Commands.Queue.add(config, thread_id, "also run the linter")

  ## What it needs at run time

  Codex looks the thread up in its local thread store under
  `$CODEX_HOME`, or on the app server given with `:remote`. An unknown
  thread exits 1 with `failed to queue session message: thread/queue/add
  failed: failed to read thread: ... no rollout found for thread id ...`
  (codex-cli 0.165.0), returned as `{:error, {:exit, 1, output}}`.

  The message travels in argv, so it is visible in the process table, and
  it is subject to the platform's argument length limits.

  ## Options

    * `:remote` - app server endpoint: `ws://host:port`, `wss://host:port`,
      `unix://` or `unix://PATH` (`--remote`)
    * `:remote_auth_token_env` - name of the environment variable holding
      the bearer token for a remote websocket (`--remote-auth-token-env`)
    * `:model`, `:profile`, `:local_provider`, `:cd` - strings
    * `:add_dir` - directory, or a list of them
    * `:sandbox` - `:read_only`, `:workspace_write` or `:danger_full_access`
    * `:oss`, `:approve_for_me`, `:strict_config`,
      `:dangerously_bypass_approvals_and_sandbox`,
      `:dangerously_bypass_hook_trust` - booleans
    * `:config` (`-c`), `:enable`, `:disable` - string or list

  An unknown option or a value of the wrong type raises `ArgumentError`.

  `codex queue --help` also lists `--image` and `--worktree`, but
  codex-cli 0.165.0 rejects both at run time ("`codex queue` does not
  support image attachments", "`--worktree` supports new interactive
  sessions, `codex fork`, `codex exec`, and `codex exec fork`"), so there
  are no options for them.
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config}

  @type t :: %__MODULE__{thread: String.t(), message: String.t(), opts: keyword()}

  @enforce_keys [:thread, :message]
  defstruct [:thread, :message, opts: []]

  @strings [
    remote: "--remote",
    remote_auth_token_env: "--remote-auth-token-env",
    model: "--model",
    profile: "--profile",
    local_provider: "--local-provider",
    cd: "--cd"
  ]

  @lists [add_dir: "--add-dir", enable: "--enable", disable: "--disable"]

  @flags [
    oss: "--oss",
    approve_for_me: "--approve-for-me",
    strict_config: "--strict-config",
    dangerously_bypass_approvals_and_sandbox: "--dangerously-bypass-approvals-and-sandbox",
    dangerously_bypass_hook_trust: "--dangerously-bypass-hook-trust"
  ]

  @sandbox_modes [:read_only, :workspace_write, :danger_full_access]

  @doc """
  Queue `message` for `thread`. Returns the trimmed output.
  """
  @spec add(Config.t(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, thread, message, opts \\ []) do
    Command.run(__MODULE__, new(thread, message, opts), config)
  end

  @doc """
  Build the command, validating its options. Raises `ArgumentError` on an
  empty thread, a non-string message or an invalid option.
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(thread, message, opts \\ [])

  def new(thread, message, opts) when is_binary(thread) and thread != "" and is_binary(message) do
    Enum.each(opts, &validate!/1)
    %__MODULE__{thread: thread, message: message, opts: opts}
  end

  def new(thread, message, _opts) do
    raise ArgumentError,
          "queue needs a non-empty thread and a string message, got: " <>
            "#{inspect(thread)}, #{inspect(message)}"
  end

  @impl true
  def args(%__MODULE__{thread: thread, message: message, opts: opts}) do
    ["queue", "--thread=" <> thread, "--message=" <> message] ++ Enum.flat_map(opts, &option/1)
  end

  @impl true
  def parse_output(stdout, 0), do: {:ok, String.trim(stdout)}
  def parse_output(stdout, exit_code), do: {:error, {:exit, exit_code, stdout}}

  defp option({:sandbox, mode}), do: ["--sandbox=" <> sandbox(mode)]
  defp option({:config, values}), do: Enum.flat_map(List.wrap(values), &["-c", &1])

  defp option({key, value}) do
    cond do
      flag = @strings[key] -> ["#{flag}=#{value}"]
      flag = @lists[key] -> Enum.map(List.wrap(value), &"#{flag}=#{&1}")
      flag = @flags[key] -> if value, do: [flag], else: []
    end
  end

  defp sandbox(:read_only), do: "read-only"
  defp sandbox(:workspace_write), do: "workspace-write"
  defp sandbox(:danger_full_access), do: "danger-full-access"

  defp validate!({:sandbox, mode}) when mode in @sandbox_modes, do: :ok

  defp validate!({:sandbox, mode}),
    do:
      raise(
        ArgumentError,
        "option :sandbox expects one of #{inspect(@sandbox_modes)}, got: #{inspect(mode)}"
      )

  defp validate!({key, value}) when is_atom(key) do
    valid? =
      cond do
        Keyword.has_key?(@strings, key) -> is_binary(value)
        Keyword.has_key?(@lists, key) or key == :config -> strings?(value)
        Keyword.has_key?(@flags, key) -> is_boolean(value)
        true -> raise ArgumentError, "unknown option #{inspect(key)} for Commands.Queue"
      end

    unless valid?,
      do: raise(ArgumentError, "invalid value for option #{inspect(key)}: #{inspect(value)}")
  end

  defp validate!(other),
    do: raise(ArgumentError, "expected a keyword option, got: #{inspect(other)}")

  defp strings?(value),
    do: is_binary(value) or (is_list(value) and value != [] and Enum.all?(value, &is_binary/1))
end
