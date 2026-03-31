defmodule CodexWrapper.Review do
  @moduledoc """
  Review command — code review with git integration.

  Wraps `codex exec review` with review-specific CLI flags.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/repo")

      # Review uncommitted changes
      review = CodexWrapper.Review.new()
        |> CodexWrapper.Review.uncommitted()
        |> CodexWrapper.Review.model("o3")

      {:ok, result} = CodexWrapper.Review.execute(review, config)

      # Review against a base branch
      CodexWrapper.Review.new()
      |> CodexWrapper.Review.base("main")
      |> CodexWrapper.Review.execute(config)

      # Review a specific commit
      CodexWrapper.Review.new()
      |> CodexWrapper.Review.commit("abc123")
      |> CodexWrapper.Review.execute(config)
  """

  @behaviour CodexWrapper.Command

  alias CodexWrapper.{Command, Config, JsonLineEvent, Result}

  @type t :: %__MODULE__{
          prompt: String.t() | nil,
          uncommitted: boolean(),
          base: String.t() | nil,
          commit: String.t() | nil,
          title: String.t() | nil,
          model: String.t() | nil,
          full_auto: boolean(),
          dangerously_bypass_approvals_and_sandbox: boolean(),
          skip_git_repo_check: boolean(),
          ephemeral: boolean(),
          json: boolean(),
          output_last_message: String.t() | nil,
          config_overrides: [String.t()],
          enabled_features: [String.t()],
          disabled_features: [String.t()]
        }

  defstruct [
    :prompt,
    :base,
    :commit,
    :title,
    :model,
    :output_last_message,
    uncommitted: false,
    full_auto: false,
    dangerously_bypass_approvals_and_sandbox: false,
    skip_git_repo_check: false,
    ephemeral: false,
    json: false,
    config_overrides: [],
    enabled_features: [],
    disabled_features: []
  ]

  # --- Constructor ---

  @doc """
  Create a new review command.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- Builder functions ---

  @doc "Set an optional prompt for additional review context."
  @spec prompt(t(), String.t()) :: t()
  def prompt(%__MODULE__{} = r, prompt), do: %{r | prompt: prompt}

  @doc "Review uncommitted changes."
  @spec uncommitted(t()) :: t()
  def uncommitted(%__MODULE__{} = r), do: %{r | uncommitted: true}

  @doc "Compare against a base branch."
  @spec base(t(), String.t()) :: t()
  def base(%__MODULE__{} = r, branch), do: %{r | base: branch}

  @doc "Review a specific commit."
  @spec commit(t(), String.t()) :: t()
  def commit(%__MODULE__{} = r, sha), do: %{r | commit: sha}

  @doc "Set the PR/review title."
  @spec title(t(), String.t()) :: t()
  def title(%__MODULE__{} = r, title), do: %{r | title: title}

  @doc "Set the model."
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = r, model), do: %{r | model: model}

  @doc "Enable full-auto mode."
  @spec full_auto(t()) :: t()
  def full_auto(%__MODULE__{} = r), do: %{r | full_auto: true}

  @doc "Bypass all approvals and sandbox. Use with extreme caution."
  @spec dangerously_bypass_approvals_and_sandbox(t()) :: t()
  def dangerously_bypass_approvals_and_sandbox(%__MODULE__{} = r),
    do: %{r | dangerously_bypass_approvals_and_sandbox: true}

  @doc "Skip the git repo check."
  @spec skip_git_repo_check(t()) :: t()
  def skip_git_repo_check(%__MODULE__{} = r), do: %{r | skip_git_repo_check: true}

  @doc "Enable ephemeral mode (no session persistence)."
  @spec ephemeral(t()) :: t()
  def ephemeral(%__MODULE__{} = r), do: %{r | ephemeral: true}

  @doc "Enable JSON output."
  @spec json(t()) :: t()
  def json(%__MODULE__{} = r), do: %{r | json: true}

  @doc "Set the output-last-message path."
  @spec output_last_message(t(), String.t()) :: t()
  def output_last_message(%__MODULE__{} = r, path), do: %{r | output_last_message: path}

  @doc "Add a config override (key=value)."
  @spec config(t(), String.t()) :: t()
  def config(%__MODULE__{} = r, kv), do: %{r | config_overrides: r.config_overrides ++ [kv]}

  @doc "Enable a feature."
  @spec enable(t(), String.t()) :: t()
  def enable(%__MODULE__{} = r, feature),
    do: %{r | enabled_features: r.enabled_features ++ [feature]}

  @doc "Disable a feature."
  @spec disable(t(), String.t()) :: t()
  def disable(%__MODULE__{} = r, feature),
    do: %{r | disabled_features: r.disabled_features ++ [feature]}

  # --- Execution ---

  @doc """
  Execute the review command synchronously, returning a parsed `%Result{}`.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, term()}
  def execute(%__MODULE__{} = review, %Config{} = config) do
    Command.run(__MODULE__, review, config)
  end

  @doc """
  Execute the review command with `--json` and return parsed NDJSON events.

  Forces `--json` on the command, runs synchronously, then parses
  each NDJSON line from stdout.
  """
  @spec execute_json(t(), Config.t()) :: {:ok, [JsonLineEvent.t()]} | {:error, term()}
  def execute_json(%__MODULE__{} = review, %Config{} = config) do
    review = %{review | json: true}

    case execute(review, config) do
      {:ok, result} -> {:ok, JsonLineEvent.parse_lines(result.stdout)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Execute the review command and return a lazy `Stream` of `%JsonLineEvent{}`.

  Uses a Port with `:line` mode to read NDJSON output line-by-line.
  Forces `--json` on the command.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = review, %Config{} = config) do
    review = %{review | json: true}
    args = Config.base_args(config) ++ args(review)

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
  def args(%__MODULE__{} = r) do
    ["exec", "review"]
    |> add_list("-c", r.config_overrides)
    |> add_list("--enable", r.enabled_features)
    |> add_list("--disable", r.disabled_features)
    |> add_bool("--uncommitted", r.uncommitted)
    |> add_opt("--base", r.base)
    |> add_opt("--commit", r.commit)
    |> add_opt("--model", r.model)
    |> add_opt("--title", r.title)
    |> add_bool("--full-auto", r.full_auto)
    |> add_bool(
      "--dangerously-bypass-approvals-and-sandbox",
      r.dangerously_bypass_approvals_and_sandbox
    )
    |> add_bool("--skip-git-repo-check", r.skip_git_repo_check)
    |> add_bool("--ephemeral", r.ephemeral)
    |> add_bool("--json", r.json)
    |> add_opt("--output-last-message", r.output_last_message)
    |> add_prompt(r.prompt)
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

  defp add_prompt(args, nil), do: args
  defp add_prompt(args, prompt), do: args ++ [prompt]
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
end
