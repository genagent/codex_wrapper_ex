defmodule CodexWrapper.ExecFork do
  @moduledoc """
  ExecFork command -- branch an existing session into a new one, non-interactively.

  Wraps `codex exec fork <SESSION_ID> [PROMPT]`. Forking copies the source
  session's history into a new session and runs the optional prompt there.
  The source session is left as it was and stays resumable under its
  original ID.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")

      {:ok, fork} =
        CodexWrapper.ExecFork.new("019a...-source-session-id")
        |> CodexWrapper.ExecFork.prompt("try the other approach")
        |> CodexWrapper.ExecFork.fork(config)

      fork.session_id        # the new session
      fork.source_session_id # the session that was forked, unchanged

  `fork/2` is the call to use when the new session ID matters (it
  usually does). `execute/2`, `execute_json/2`, and `stream/2` behave the
  same way as they do on `CodexWrapper.ExecResume`.

  ## Arguments the CLI accepts

  Verified against codex-cli 0.149.0. `codex exec fork` accepts the
  `codex exec resume` flag set without `--last` and `--all`, plus
  `--output-schema`. It rejects `--sandbox`, `--profile`, and
  `--full-auto`, so `sandbox/2` and `full_auto/1` emit the config
  override `-c sandbox_mode="<mode>"` the same way `ExecResume` does.

  ## CLIs without `exec fork`

  An older CLI parses `fork` as the `codex exec` prompt and rejects the
  session ID as an unexpected argument. `execute/2`, `execute_json/2`, and
  `fork/2` recognize that failure and return
  `{:error, {:unsupported, :exec_fork}}`. `supported?/1` checks ahead of
  time. `stream/2` cannot see the exit status, so on an older CLI its
  stream ends without events.
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config, JsonLineEvent, Result, Runner, Session, Telemetry}

  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access

  @type t :: %__MODULE__{
          session_id: String.t(),
          prompt: String.t() | nil,
          model: String.t() | nil,
          sandbox: sandbox_mode() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          dangerously_bypass_hook_trust: boolean(),
          skip_git_repo_check: boolean(),
          ephemeral: boolean(),
          json: boolean(),
          output_schema: String.t() | nil,
          output_last_message: String.t() | nil,
          images: [String.t()],
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()],
          strict_config: boolean(),
          ignore_user_config: boolean(),
          ignore_rules: boolean()
        }

  @typedoc """
  The outcome of `fork/2`.

  `session_id` is the new session the CLI created; `source_session_id` is
  the ID that was forked, exactly as passed to `new/1`.
  """
  @type fork_result :: %{
          session_id: String.t(),
          source_session_id: String.t(),
          result: Result.t(),
          events: [JsonLineEvent.t()]
        }

  @type error ::
          {:invalid_session_id, term()}
          | {:unsupported, :exec_fork}
          | {:exit, non_neg_integer(), Result.t()}
          | {:missing_session_id, Result.t()}
          | term()

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    :prompt,
    :model,
    :output_schema,
    :output_last_message,
    :sandbox,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    dangerously_bypass_hook_trust: false,
    skip_git_repo_check: false,
    ephemeral: false,
    json: false,
    images: [],
    config_overrides: [],
    enabled_features: [],
    disabled_features: [],
    strict_config: false,
    ignore_user_config: false,
    ignore_rules: false
  ]

  # --- Constructor ---

  @doc """
  Create a fork of the session with the given ID (a UUID or a thread name).

  The ID is checked by `validate/1` when the command runs, not here, so a
  builder can be assembled from untrusted input and rejected with a
  tagged error rather than an exception.
  """
  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  # --- Builder functions ---

  @doc "Set the prompt to send in the new session after forking."
  @spec prompt(t(), String.t()) :: t()
  def prompt(%__MODULE__{} = e, prompt), do: %{e | prompt: prompt}

  @doc "Set the model."
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = e, model), do: %{e | model: model}

  @doc """
  Set the sandbox mode.

  Emits `-c sandbox_mode="<mode>"`: `codex exec fork` rejects `--sandbox`
  with `unexpected argument`, and the config key takes the same three
  values.
  """
  @spec sandbox(t(), sandbox_mode()) :: t()
  def sandbox(%__MODULE__{} = e, mode), do: %{e | sandbox: mode}

  @doc """
  Enable full-auto mode.

  Deprecated upstream, and `codex exec fork` rejects `--full-auto`. Emits
  `-c sandbox_mode="workspace-write"` instead. An explicit `sandbox/2`
  call is more specific and wins over this.
  """
  @spec full_auto(t()) :: t()
  def full_auto(%__MODULE__{} = e), do: %{e | full_auto: true}

  @doc "Bypass all approvals and sandbox. Use with extreme caution."
  @spec dangerously_bypass_approvals_and_sandbox(t()) :: t()
  def dangerously_bypass_approvals_and_sandbox(%__MODULE__{} = e),
    do: %{e | dangerously_bypass_approvals_and_sandbox: true}

  @doc """
  Run enabled hooks without requiring persisted hook trust. Use with extreme caution.

  Hook trust is what stops a repository from running arbitrary commands
  the user never approved. Only appropriate for automation that already
  vets where its hooks come from.
  """
  @spec dangerously_bypass_hook_trust(t()) :: t()
  def dangerously_bypass_hook_trust(%__MODULE__{} = e),
    do: %{e | dangerously_bypass_hook_trust: true}

  @doc "Error out when `config.toml` contains fields this Codex version does not recognize."
  @spec strict_config(t()) :: t()
  def strict_config(%__MODULE__{} = e), do: %{e | strict_config: true}

  @doc "Do not load `$CODEX_HOME/config.toml`. Auth still resolves through `CODEX_HOME`."
  @spec ignore_user_config(t()) :: t()
  def ignore_user_config(%__MODULE__{} = e), do: %{e | ignore_user_config: true}

  @doc "Do not load user or project execpolicy `.rules` files."
  @spec ignore_rules(t()) :: t()
  def ignore_rules(%__MODULE__{} = e), do: %{e | ignore_rules: true}

  @doc "Skip the git repo check."
  @spec skip_git_repo_check(t()) :: t()
  def skip_git_repo_check(%__MODULE__{} = e), do: %{e | skip_git_repo_check: true}

  @doc "Enable ephemeral mode: the new session is not persisted to disk."
  @spec ephemeral(t()) :: t()
  def ephemeral(%__MODULE__{} = e), do: %{e | ephemeral: true}

  @doc "Enable JSON output."
  @spec json(t()) :: t()
  def json(%__MODULE__{} = e), do: %{e | json: true}

  @doc "Set the path of a JSON Schema file describing the final response shape."
  @spec output_schema(t(), String.t()) :: t()
  def output_schema(%__MODULE__{} = e, path), do: %{e | output_schema: path}

  @doc "Set the output-last-message path."
  @spec output_last_message(t(), String.t()) :: t()
  def output_last_message(%__MODULE__{} = e, path), do: %{e | output_last_message: path}

  @doc "Add an image to attach to the prompt sent after forking."
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

  # --- Validation ---

  @doc """
  Check the source session ID before it reaches the CLI.

  Accepts a non-empty string with no leading or trailing whitespace, no
  control characters, and no leading `-` (which the CLI would parse as a
  flag). Both UUIDs and thread names pass. Anything else returns
  `{:error, {:invalid_session_id, value}}`.
  """
  @spec validate(t()) :: :ok | {:error, {:invalid_session_id, term()}}
  def validate(%__MODULE__{session_id: id}) do
    if valid_session_id?(id), do: :ok, else: {:error, {:invalid_session_id, id}}
  end

  defp valid_session_id?(id) when is_binary(id) and id != "" do
    String.trim(id) == id and
      not String.starts_with?(id, "-") and
      String.valid?(id) and
      not String.match?(id, ~r/[[:cntrl:]]/u)
  end

  defp valid_session_id?(_), do: false

  # --- Capability ---

  @doc """
  Return whether the installed CLI has `codex exec fork`.

  Runs `codex exec fork --help`, which needs no authentication and starts
  no session.
  """
  @spec supported?(Config.t()) :: boolean()
  def supported?(%Config{} = config) do
    args = Config.base_args(config) ++ ["exec", "fork", "--help"]

    case Runner.impl().run(config.binary, args, Config.cmd_opts(config), config.timeout) do
      {:ok, {out, 0}} -> String.contains?(out, "exec fork")
      _ -> false
    end
  end

  # --- Execution ---

  @doc """
  Execute the command synchronously, returning a parsed `%Result{}`.

  A non-zero exit is still `{:ok, %Result{success: false}}`, as with
  `ExecResume.execute/2`, except when the CLI has no `exec fork`, which
  returns `{:error, {:unsupported, :exec_fork}}`. An invalid session ID
  returns `{:error, {:invalid_session_id, value}}` without spawning.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, error()}
  def execute(%__MODULE__{} = exec, %Config{} = config) do
    with :ok <- validate(exec) do
      Telemetry.span(
        [:codex_wrapper, :exec],
        Telemetry.exec_metadata(:exec_fork, exec),
        fn ->
          __MODULE__
          |> Command.run(exec, config)
          |> check_supported(exec)
        end
      )
    end
  end

  @doc """
  Execute with `--json` and return the parsed `%JsonLineEvent{}` list.
  """
  @spec execute_json(t(), Config.t()) :: {:ok, [JsonLineEvent.t()]} | {:error, error()}
  def execute_json(%__MODULE__{} = exec, %Config{} = config) do
    case execute(%{exec | json: true}, config) do
      {:ok, result} -> {:ok, JsonLineEvent.parse_lines(result.stdout)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Fork the session and return the new session ID alongside the source.

  Forces `--json`. Returns `{:ok, fork_result()}` when the CLI exits 0
  and reports the new thread ID in its `thread.started` event. The new ID
  comes from the CLI's output, never from the builder, so
  `source_session_id` is always the ID that was forked.

  Errors:

    * `{:invalid_session_id, value}` -- rejected before spawning
    * `{:unsupported, :exec_fork}` -- the installed CLI has no `exec fork`
    * `{:exit, code, result}` -- the CLI exited non-zero (for example, an
      unknown source session: `no rollout found for thread id`)
    * `{:missing_session_id, result}` -- exit 0 without a new thread ID
    * `{:timeout, ms}` and runner errors, as from `execute/2`
  """
  @spec fork(t(), Config.t()) :: {:ok, fork_result()} | {:error, error()}
  def fork(%__MODULE__{} = exec, %Config{} = config) do
    with {:ok, %Result{} = result} <- execute(%{exec | json: true}, config) do
      to_fork_result(result, exec.session_id)
    end
  end

  defp to_fork_result(%Result{success: false, exit_code: code} = result, _source),
    do: {:error, {:exit, code, result}}

  defp to_fork_result(%Result{} = result, source) do
    events = JsonLineEvent.parse_lines(result.stdout)

    case Session.extract_session_id(events) do
      id when is_binary(id) and id != "" ->
        {:ok, %{session_id: id, source_session_id: source, result: result, events: events}}

      _ ->
        {:error, {:missing_session_id, result}}
    end
  end

  @doc """
  Execute the command and return a lazy `Stream` of `%JsonLineEvent{}`.

  Forces `--json`. Raises `ArgumentError` for an invalid session ID,
  since a stream has no error tuple to return. The new session ID is in
  the first `thread.started` event.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = exec, %Config{} = config) do
    case validate(exec) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "invalid exec fork session id: #{inspect(reason)}"
    end

    exec = %{exec | json: true}

    Telemetry.span_stream(
      [:codex_wrapper, :stream],
      Telemetry.exec_metadata(:exec_fork, exec),
      fn ->
        args = Config.base_args(config) ++ args(exec)

        config.binary
        |> Runner.stream_lines(args, Config.stream_opts(config), config.timeout)
        |> JsonLineEvent.parse_stream()
      end
    )
  end

  # An older CLI parses `fork` as the `codex exec` prompt and then trips
  # over the session ID (`unexpected argument '<id>' found`); a CLI that
  # grew subcommand parsing but not `fork` would say so directly.
  defp check_supported({:ok, %Result{success: false, stdout: out}} = ok, exec) do
    if String.contains?(out, "unexpected argument '#{exec.session_id}'") or
         String.contains?(out, "unrecognized subcommand 'fork'") do
      {:error, {:unsupported, :exec_fork}}
    else
      ok
    end
  end

  defp check_supported(other, _exec), do: other

  # --- Command behaviour ---

  @impl Command
  def args(%__MODULE__{} = e) do
    ["exec", "fork"]
    |> add_list("-c", config_overrides(e))
    |> add_list("--enable", e.enabled_features)
    |> add_list("--disable", e.disabled_features)
    |> add_list("--image", e.images)
    |> add_bool("--strict-config", e.strict_config)
    |> add_opt("--model", e.model)
    |> add_bool(
      "--dangerously-bypass-approvals-and-sandbox",
      e.dangerously_bypass_approvals_and_sandbox
    )
    |> add_bool("--dangerously-bypass-hook-trust", e.dangerously_bypass_hook_trust)
    |> add_bool("--skip-git-repo-check", e.skip_git_repo_check)
    |> add_bool("--ephemeral", e.ephemeral)
    |> add_bool("--ignore-user-config", e.ignore_user_config)
    |> add_bool("--ignore-rules", e.ignore_rules)
    |> add_opt("--output-schema", e.output_schema)
    |> add_bool("--json", e.json)
    |> add_opt("--output-last-message", e.output_last_message)
    |> add_positional(e.session_id)
    |> add_positional(e.prompt)
  end

  @impl Command
  def parse_output(stdout, exit_code), do: {:ok, Result.from_cmd({stdout, exit_code})}

  # --- Arg helpers ---

  defp add_positional(args, nil), do: args
  defp add_positional(args, value), do: args ++ [value]
  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

  # `codex exec fork` rejects `--sandbox`; `sandbox_mode` is the config key
  # it accepts. User-supplied overrides come first, so the builder's
  # sandbox wins on a last-wins CLI, matching ExecResume.
  defp config_overrides(%__MODULE__{} = e) do
    e.config_overrides ++ sandbox_override(e)
  end

  defp sandbox_override(%__MODULE__{} = e) do
    case format_sandbox(effective_sandbox(e)) do
      nil -> []
      mode -> [~s(sandbox_mode="#{mode}")]
    end
  end

  defp effective_sandbox(%__MODULE__{sandbox: nil, full_auto: true}), do: :workspace_write
  defp effective_sandbox(%__MODULE__{sandbox: mode}), do: mode

  defp format_sandbox(nil), do: nil
  defp format_sandbox(:read_only), do: "read-only"
  defp format_sandbox(:workspace_write), do: "workspace-write"
  defp format_sandbox(:danger_full_access), do: "danger-full-access"
end
