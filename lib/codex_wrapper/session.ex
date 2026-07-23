defmodule CodexWrapper.Session do
  @moduledoc """
  Multi-turn session management.

  Wraps repeated `Exec` / `ExecResume` calls, automatically threading the
  `session_id` so each turn continues the same conversation.

  The first turn uses `Exec` to create a new session. Subsequent turns
  use `ExecResume` with the session ID extracted from the JSON output.

  ## Usage

      config = CodexWrapper.Config.new(working_dir: "/path/to/project")
      session = CodexWrapper.Session.new(config)

      {:ok, session, result} = CodexWrapper.Session.send(session, "What files are in this project?")
      {:ok, session, result} = CodexWrapper.Session.send(session, "Now add tests for lib/foo.ex")

      # Access history
      CodexWrapper.Session.turns(session)
      #=> [%Result{...}, %Result{...}]

      # Resume a previous session
      session = CodexWrapper.Session.resume(config, "session-id-abc")
  """

  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent, Result}

  @type t :: %__MODULE__{
          config: Config.t(),
          session_id: String.t() | nil,
          history: [Result.t()],
          exec_opts: keyword()
        }

  defstruct [
    :config,
    :session_id,
    history: [],
    exec_opts: []
  ]

  @doc """
  Create a new session with the given config.

  ## Options

  Any option accepted by `CodexWrapper.exec/2` (exec-level options only):

    * `:model` - Model name
    * `:profile` - Named config profile (`--profile`)
    * `:sandbox` - Sandbox mode
    * `:approval_policy` - Approval policy (`:untrusted`, `:on_request`, `:never`)
    * `:full_auto` - Enable full-auto (boolean)
    * `:dangerously_bypass_approvals_and_sandbox` - Bypass all (boolean)
    * `:skip_git_repo_check` - Skip git check (boolean)
  """
  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    %__MODULE__{config: config, exec_opts: opts}
  end

  @doc """
  Resume an existing session by ID.
  """
  @spec resume(Config.t(), String.t(), keyword()) :: t()
  def resume(%Config{} = config, session_id, opts \\ []) do
    %__MODULE__{config: config, session_id: session_id, exec_opts: opts}
  end

  @doc """
  Send a message in the session. Returns the updated session and result.

  The first turn creates a new session via `Exec`. Subsequent turns use
  `ExecResume` with the session ID from the first result.

  Internally uses `--json` to extract the session ID from NDJSON events.
  """
  @spec send(t(), String.t(), keyword()) :: {:ok, t(), Result.t()} | {:error, term()}
  def send(%__MODULE__{} = session, prompt, opts \\ []) do
    case execute_turn(session, prompt, opts) do
      {:ok, result, events} ->
        new_session_id = extract_session_id(events) || session.session_id

        updated = %{
          session
          | session_id: new_session_id,
            history: session.history ++ [result]
        }

        {:ok, updated, result}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Send a message and return a stream of events.

  Returns `{session, stream}`. The returned `session` is the **same
  session passed in** -- this function does *not* thread `session_id`
  across turns. If you need multi-turn continuity, use `send/3`
  instead, which runs the turn synchronously and updates `session_id`
  from the final events.

  Use `stream/3` when you want to observe events from a single turn
  (for example, to render intermediate output as the CLI produces it)
  and do not need to chain into a follow-up turn on the same thread.
  """
  @spec stream(t(), String.t(), keyword()) :: {t(), Enumerable.t()}
  def stream(%__MODULE__{} = session, prompt, opts \\ []) do
    raw_stream = build_stream(session, prompt, opts)
    {session, raw_stream}
  end

  @doc """
  Get the session ID (if established).
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{session_id: sid}) when is_binary(sid), do: sid
  def session_id(%__MODULE__{}), do: nil

  @doc """
  Get the conversation history (list of results).
  """
  @spec turns(t()) :: [Result.t()]
  def turns(%__MODULE__{history: history}), do: history

  @doc """
  Alias for `turns/1`.
  """
  @spec history(t()) :: [Result.t()]
  def history(%__MODULE__{} = session), do: turns(session)

  @doc """
  Get the number of completed turns.
  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{history: history}), do: length(history)

  @doc """
  Get the total cost across all turns.

  Returns `0.0` as the Codex CLI does not currently expose per-turn cost.
  This is provided for API compatibility with future cost reporting.
  """
  @spec total_cost(t()) :: float()
  def total_cost(%__MODULE__{}), do: 0.0

  @doc """
  Get the last result, if any.
  """
  @spec last_result(t()) :: Result.t() | nil
  def last_result(%__MODULE__{history: []}), do: nil
  def last_result(%__MODULE__{history: history}), do: List.last(history)

  # --- Private ---

  defp execute_turn(%__MODULE__{session_id: nil} = session, prompt, per_call_opts) do
    exec = build_exec(session, prompt, per_call_opts)

    case Exec.execute_json(exec, session.config) do
      {:ok, events} ->
        result = events_to_result(events)
        {:ok, result, events}

      {:error, _} = error ->
        error
    end
  end

  defp execute_turn(%__MODULE__{session_id: sid} = session, prompt, per_call_opts)
       when is_binary(sid) do
    exec_resume = build_exec_resume(session, prompt, per_call_opts)

    case ExecResume.execute_json(exec_resume, session.config) do
      {:ok, events} ->
        result = events_to_result(events)
        {:ok, result, events}

      {:error, _} = error ->
        error
    end
  end

  defp build_exec(session, prompt, per_call_opts) do
    merged_opts = Keyword.merge(session.exec_opts, per_call_opts)
    exec = Exec.new(prompt)

    Enum.reduce(merged_opts, exec, fn
      {:model, v}, e ->
        Exec.model(e, v)

      {:profile, v}, e ->
        Exec.profile(e, v)

      {:sandbox, v}, e ->
        Exec.sandbox(e, v)

      {:approval_policy, v}, e ->
        Exec.approval_policy(e, v)

      {:full_auto, true}, e ->
        Exec.full_auto(e)

      {:skip_git_repo_check, true}, e ->
        Exec.skip_git_repo_check(e)

      {:ephemeral, true}, e ->
        Exec.ephemeral(e)

      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        Exec.dangerously_bypass_approvals_and_sandbox(e)

      _other, e ->
        e
    end)
  end

  defp build_exec_resume(session, prompt, per_call_opts) do
    merged_opts = Keyword.merge(session.exec_opts, per_call_opts)

    resume =
      ExecResume.new()
      |> ExecResume.session_id(session.session_id)
      |> ExecResume.prompt(prompt)

    Enum.reduce(merged_opts, resume, fn
      {:model, v}, e ->
        ExecResume.model(e, v)

      {:profile, v}, e ->
        ExecResume.profile(e, v)

      {:full_auto, true}, e ->
        ExecResume.full_auto(e)

      {:skip_git_repo_check, true}, e ->
        ExecResume.skip_git_repo_check(e)

      {:ephemeral, true}, e ->
        ExecResume.ephemeral(e)

      {:dangerously_bypass_approvals_and_sandbox, true}, e ->
        ExecResume.dangerously_bypass_approvals_and_sandbox(e)

      _other, e ->
        e
    end)
  end

  defp build_stream(%__MODULE__{session_id: nil} = session, prompt, per_call_opts) do
    exec = build_exec(session, prompt, per_call_opts)
    Exec.stream(exec, session.config)
  end

  defp build_stream(%__MODULE__{session_id: sid} = session, prompt, per_call_opts)
       when is_binary(sid) do
    exec_resume = build_exec_resume(session, prompt, per_call_opts)
    ExecResume.stream(exec_resume, session.config)
  end

  # Public with @doc false so the session-id-capture logic can be covered
  # by regression tests -- see SessionTest `describe "extract_session_id/1"`.
  # Codex 0.119+ emits the thread identifier as `"thread_id"` in the first
  # `thread.started` event. Older versions (or other forks) may still use
  # `"session_id"`, so we check both.
  @doc false
  @spec extract_session_id([JsonLineEvent.t()]) :: String.t() | nil
  def extract_session_id(events) do
    Enum.find_value(events, fn event ->
      JsonLineEvent.get(event, "thread_id") || JsonLineEvent.get(event, "session_id")
    end)
  end

  defp events_to_result(events) do
    stdout = Enum.map_join(events, "\n", fn event -> event.raw end)

    %Result{
      stdout: stdout,
      stderr: "",
      exit_code: 0,
      success: true
    }
  end
end
