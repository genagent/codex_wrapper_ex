defmodule CodexWrapper.Exec do
  @moduledoc """
  Exec command -- the primary interface for non-interactive prompts.

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

  alias CodexWrapper.{Command, Config, JsonLineEvent, Result, Runner, Telemetry}

  @type sandbox_mode :: :read_only | :workspace_write | :danger_full_access
  @type approval_policy :: :untrusted | :on_request | :never
  @type web_search_mode :: :cached | :indexed | :live | :disabled
  @type color_mode :: :always | :never | :auto

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: String.t() | nil,
          profile: String.t() | nil,
          sandbox: sandbox_mode() | nil,
          approval_policy: approval_policy() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          dangerously_bypass_hook_trust: boolean(),
          cd: String.t() | nil,
          skip_git_repo_check: boolean(),
          add_dirs: [String.t()],
          search: web_search_mode() | nil,
          ephemeral: boolean(),
          output_schema: String.t() | nil,
          json: boolean(),
          output_last_message: String.t() | nil,
          images: [String.t()],
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()],
          strict_config: boolean(),
          ignore_user_config: boolean(),
          ignore_rules: boolean(),
          color: color_mode() | nil,
          oss: boolean(),
          local_provider: String.t() | nil
        }

  defstruct [
    :prompt,
    :model,
    :profile,
    :sandbox,
    :approval_policy,
    :cd,
    :output_schema,
    :output_last_message,
    :search,
    :color,
    :local_provider,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    dangerously_bypass_hook_trust: false,
    skip_git_repo_check: false,
    ephemeral: false,
    json: false,
    add_dirs: [],
    images: [],
    config_overrides: [],
    enabled_features: [],
    disabled_features: [],
    strict_config: false,
    ignore_user_config: false,
    ignore_rules: false,
    oss: false
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

  @doc """
  Select a named config profile.

  Emits `--profile <name>`, which tells the Codex CLI to load the
  `[profiles.<name>]` section of `config.toml`.
  """
  @spec profile(t(), String.t()) :: t()
  def profile(%__MODULE__{} = e, name), do: %{e | profile: name}

  @doc "Set the sandbox mode."
  @spec sandbox(t(), sandbox_mode()) :: t()
  def sandbox(%__MODULE__{} = e, mode), do: %{e | sandbox: mode}

  @doc """
  Set the approval policy.

  One of `:untrusted`, `:on_request`, or `:never`. Emitted as the
  `-c approval_policy="<value>"` config override: codex-cli 0.14x removed
  the `--ask-for-approval` flag from `exec`, and the config key is the
  supported equivalent.

  `:on_failure` was accepted by the old flag and is no longer a valid
  policy; passing it raises.
  """
  @spec approval_policy(t(), approval_policy()) :: t()
  def approval_policy(%__MODULE__{}, :on_failure) do
    raise ArgumentError, """
    :on_failure is no longer a valid approval policy.

    The Codex CLI dropped it along with the --ask-for-approval flag.
    Valid policies are :untrusted, :on_request, and :never.
    """
  end

  def approval_policy(%__MODULE__{} = e, policy) when policy in [:untrusted, :on_request, :never],
    do: %{e | approval_policy: policy}

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

  @doc """
  Run enabled hooks without requiring persisted hook trust. Use with extreme caution.

  Hook trust is what stops a repository from running arbitrary commands
  the user never approved. Only appropriate for automation that already
  vets where its hooks come from.
  """
  @spec dangerously_bypass_hook_trust(t()) :: t()
  def dangerously_bypass_hook_trust(%__MODULE__{} = e),
    do: %{e | dangerously_bypass_hook_trust: true}

  @doc """
  Error out when `config.toml` contains fields this Codex version does not recognize.

  Turns a silently-ignored typo in a config file into a failed run, which
  is usually what a programmatic caller wants.
  """
  @spec strict_config(t()) :: t()
  def strict_config(%__MODULE__{} = e), do: %{e | strict_config: true}

  @doc """
  Do not load `$CODEX_HOME/config.toml`.

  Auth still resolves through `CODEX_HOME`; only the config file is
  skipped. Pair with `config/2` overrides for a run that does not pick up
  the developer's personal settings.
  """
  @spec ignore_user_config(t()) :: t()
  def ignore_user_config(%__MODULE__{} = e), do: %{e | ignore_user_config: true}

  @doc "Do not load user or project execpolicy `.rules` files."
  @spec ignore_rules(t()) :: t()
  def ignore_rules(%__MODULE__{} = e), do: %{e | ignore_rules: true}

  @doc """
  Set the color mode: `:always`, `:never`, or `:auto`.

  The CLI defaults to `:auto`, which already suppresses color when stdout
  is not a terminal. `:never` is worth setting explicitly when the output
  is parsed.
  """
  @spec color(t(), color_mode()) :: t()
  def color(%__MODULE__{} = e, mode) when mode in [:always, :never, :auto],
    do: %{e | color: mode}

  @doc "Use an open-source provider instead of the default."
  @spec oss(t()) :: t()
  def oss(%__MODULE__{} = e), do: %{e | oss: true}

  @doc """
  Select which local provider to use (`"lmstudio"` or `"ollama"`).

  Meaningful alongside `oss/1`; without it the CLI uses the config
  default or prompts for a selection.
  """
  @spec local_provider(t(), String.t()) :: t()
  def local_provider(%__MODULE__{} = e, provider), do: %{e | local_provider: provider}

  @doc "Set the working directory for the codex subprocess."
  @spec cd(t(), String.t()) :: t()
  def cd(%__MODULE__{} = e, dir), do: %{e | cd: dir}

  @doc "Skip the git repo check."
  @spec skip_git_repo_check(t()) :: t()
  def skip_git_repo_check(%__MODULE__{} = e), do: %{e | skip_git_repo_check: true}

  @doc "Add a directory for context."
  @spec add_dir(t(), String.t()) :: t()
  def add_dir(%__MODULE__{} = e, dir), do: %{e | add_dirs: e.add_dirs ++ [dir]}

  @doc """
  Enable live web search.

  Shorthand for `search(exec, :live)`.
  """
  @spec search(t()) :: t()
  def search(%__MODULE__{} = e), do: search(e, :live)

  @doc """
  Set the web search mode.

  One of `:cached`, `:indexed`, `:live`, or `:disabled`. Emitted as the
  `-c web_search="<mode>"` config override: codex-cli 0.14x removed the
  `--search` flag from `exec`, and the config key is the supported
  equivalent. `:live` is what `--search` used to mean.
  """
  @spec search(t(), web_search_mode()) :: t()
  def search(%__MODULE__{} = e, mode) when mode in [:cached, :indexed, :live, :disabled],
    do: %{e | search: mode}

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
    Telemetry.span([:codex_wrapper, :exec], Telemetry.exec_metadata(:exec, exec), fn ->
      Command.run(__MODULE__, exec, config)
    end)
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
      {:ok, result} -> {:ok, JsonLineEvent.parse_lines(result.stdout)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Execute the command and return a lazy `Stream` of `%JsonLineEvent{}`.

  Reads NDJSON output line-by-line through the configured
  `CodexWrapper.Runner`. The process starts when the stream is consumed
  and is terminated when the stream halts. Lines that do not parse as
  JSON are skipped.

  Forces `--json` on the exec command.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = exec, %Config{} = config) do
    exec = %{exec | json: true}

    Telemetry.span_stream(
      [:codex_wrapper, :stream],
      Telemetry.exec_metadata(:exec, exec),
      fn ->
        args = Config.base_args(config) ++ args(exec)

        config.binary
        |> Runner.stream_lines(args, Config.stream_opts(config), config.timeout)
        |> JsonLineEvent.parse_stream()
      end
    )
  end

  # --- Command behaviour ---

  @impl Command
  def args(%__MODULE__{} = e) do
    ["exec"]
    |> add_list("-c", config_overrides(e))
    |> add_list("--enable", e.enabled_features)
    |> add_list("--disable", e.disabled_features)
    |> add_bool("--strict-config", e.strict_config)
    |> add_list("--image", e.images)
    |> add_opt("--model", e.model)
    |> add_bool("--oss", e.oss)
    |> add_opt("--local-provider", e.local_provider)
    |> add_opt("--profile", e.profile)
    |> add_opt("--sandbox", format_sandbox(effective_sandbox(e)))
    |> add_bool(
      "--dangerously-bypass-approvals-and-sandbox",
      e.dangerously_bypass_approvals_and_sandbox
    )
    |> add_bool("--dangerously-bypass-hook-trust", e.dangerously_bypass_hook_trust)
    |> add_opt("--cd", e.cd)
    |> add_bool("--skip-git-repo-check", e.skip_git_repo_check)
    |> add_list("--add-dir", e.add_dirs)
    |> add_bool("--ephemeral", e.ephemeral)
    |> add_bool("--ignore-user-config", e.ignore_user_config)
    |> add_bool("--ignore-rules", e.ignore_rules)
    |> add_opt("--output-schema", e.output_schema)
    |> add_opt("--color", format_color(e.color))
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

  # `--full-auto` is deprecated upstream ("use --sandbox workspace-write"),
  # so translate it instead of emitting it. An explicit sandbox/2 call is
  # the more specific instruction and wins.
  defp effective_sandbox(%__MODULE__{sandbox: nil, full_auto: true}), do: :workspace_write
  defp effective_sandbox(%__MODULE__{sandbox: mode}), do: mode

  defp format_sandbox(nil), do: nil
  defp format_sandbox(:read_only), do: "read-only"
  defp format_sandbox(:workspace_write), do: "workspace-write"
  defp format_sandbox(:danger_full_access), do: "danger-full-access"

  defp format_color(nil), do: nil
  defp format_color(:always), do: "always"
  defp format_color(:never), do: "never"
  defp format_color(:auto), do: "auto"

  # `--search` and `--ask-for-approval` were both removed from `codex exec`
  # in 0.14x; their config keys are the supported equivalents, so both
  # builder options fold into the `-c` overrides rather than dropping.
  # User-supplied overrides come first, so an explicit `config(...)` still
  # wins on a last-wins CLI.
  defp config_overrides(%__MODULE__{} = e) do
    e.config_overrides ++ approval_override(e) ++ web_search_override(e)
  end

  defp approval_override(%__MODULE__{approval_policy: nil}), do: []

  defp approval_override(%__MODULE__{approval_policy: policy}),
    do: [~s(approval_policy="#{format_approval_policy(policy)}")]

  defp web_search_override(%__MODULE__{search: nil}), do: []

  defp web_search_override(%__MODULE__{search: mode}),
    do: [~s(web_search="#{format_web_search(mode)}")]

  defp format_web_search(:cached), do: "cached"
  defp format_web_search(:indexed), do: "indexed"
  defp format_web_search(:live), do: "live"
  defp format_web_search(:disabled), do: "disabled"

  defp format_approval_policy(:untrusted), do: "untrusted"
  defp format_approval_policy(:on_request), do: "on-request"
  defp format_approval_policy(:never), do: "never"

  # --- Port helpers ---
end
