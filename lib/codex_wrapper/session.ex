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

  alias CodexWrapper.Commands.Archive
  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent, Options, Result, Telemetry}

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

  Any exec option accepted by `CodexWrapper.exec/2`. The options apply to
  every turn, with two exceptions:

    * `:profile`, `:cd`, `:add_dir`, `:color`, `:oss`, `:local_provider`,
      `:search`, `:approve_for_me`, `:worktree`, `:thread_source` and
      `:cyber_access_program` apply to the first turn only, since the
      `ExecResume` builder cannot emit them. They are skipped on resumed turns, and passing one to
      `send/3` or `stream/3` on a resumed turn raises `ArgumentError`.
    * `:sandbox` and `:approval_policy` are emitted on resumed turns as
      `-c sandbox_mode="..."` and `-c approval_policy="..."`.

  An unknown option, or a value of the wrong type, raises `ArgumentError`.
  """
  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    _ = Options.exec("", opts)
    %__MODULE__{config: config, exec_opts: opts}
  end

  @doc """
  Resume an existing session by ID.

  Takes the options `new/2` takes, except the first-turn-only ones listed
  there: every turn of a resumed session runs `codex exec resume`, so
  they raise `ArgumentError` here.
  """
  @spec resume(Config.t(), String.t(), keyword()) :: t()
  def resume(%Config{} = config, session_id, opts \\ []) do
    _ = Options.exec_resume(session_id, "", opts)
    %__MODULE__{config: config, session_id: session_id, exec_opts: opts}
  end

  @doc """
  Send a message in the session. Returns the updated session and result.

  The first turn creates a new session via `Exec`. Subsequent turns use
  `ExecResume` with the session ID from the first result.

  Internally uses `--json` and takes the session ID from the turn's
  `thread.started` event.

  Returns:

    * `{:ok, session, result}` when codex exited 0. `result` carries the
      turn's real output and exit code.
    * `{:error, {:exit, code, result}}` when codex exited nonzero. The
      session is unchanged: no history entry and the same session ID.
    * `{:error, {:thread_mismatch, expected, reported, result}}` when a
      session resumed by UUID reports a different thread ID. The session is
      unchanged. A session resumed by thread name adopts the reported ID.
    * `{:error, reason}` when codex could not be run or timed out.
  """
  @spec send(t(), String.t(), keyword()) ::
          {:ok, t(), Result.t()}
          | {:error,
             {:exit, non_neg_integer(), Result.t()}
             | {:thread_mismatch, String.t(), String.t(), Result.t()}
             | term()}
  def send(%__MODULE__{} = session, prompt, opts \\ []) do
    with {:ok, result, events} <- execute_turn(session, prompt, opts),
         {:ok, session_id} <- next_session_id(session.session_id, events, result) do
      updated = %{session | session_id: session_id, history: session.history ++ [result]}
      {:ok, updated, result}
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

  Returns `nil`: the Codex CLI reports token usage but no cost, so there
  is no cost to sum. The function keeps the shape of the claude_wrapper
  session API; callers that add up cost across providers should treat
  `nil` as unknown, not as zero.
  """
  @spec total_cost(t()) :: float() | nil
  def total_cost(%__MODULE__{}), do: nil

  @doc """
  Get the last result, if any.
  """
  @spec last_result(t()) :: Result.t() | nil
  def last_result(%__MODULE__{history: []}), do: nil
  def last_result(%__MODULE__{history: history}), do: List.last(history)

  @doc """
  Archive this session (`codex archive`). Reversible with `unarchive/1`.

  Returns `{:error, :no_session}` if no turn has run yet, since the
  session id only exists once the CLI has created it.
  """
  @spec archive(t()) :: {:ok, String.t()} | {:error, :no_session | term()}
  def archive(%__MODULE__{session_id: nil}), do: {:error, :no_session}

  def archive(%__MODULE__{session_id: sid, config: config}),
    do: Archive.archive(config, sid)

  @doc """
  Unarchive this session (`codex unarchive`).

  Returns `{:error, :no_session}` if no turn has run yet.
  """
  @spec unarchive(t()) :: {:ok, String.t()} | {:error, :no_session | term()}
  def unarchive(%__MODULE__{session_id: nil}), do: {:error, :no_session}

  def unarchive(%__MODULE__{session_id: sid, config: config}),
    do: Archive.unarchive(config, sid)

  @doc """
  Permanently delete this session (`codex delete`).

  Requires `confirm: true`, like `CodexWrapper.Commands.Archive.delete/3`
  it delegates to; without it the CLI is not invoked. Returns
  `{:error, :no_session}` if no turn has run yet.
  """
  @spec delete(t(), keyword()) ::
          {:ok, String.t()} | {:error, :no_session | :confirmation_required | term()}
  def delete(session, opts \\ [])

  def delete(%__MODULE__{session_id: nil}, _opts), do: {:error, :no_session}

  def delete(%__MODULE__{session_id: sid, config: config}, opts),
    do: Archive.delete(config, sid, opts)

  # --- Private ---

  defp execute_turn(%__MODULE__{session_id: nil} = session, prompt, per_call_opts) do
    exec = build_exec(session, prompt, per_call_opts)

    metadata = Telemetry.session_turn_metadata(:session_exec, exec, session.session_id)

    Telemetry.span([:codex_wrapper, :session, :turn], metadata, fn ->
      exec |> Exec.json() |> Exec.execute(session.config) |> turn_outcome()
    end)
  end

  defp execute_turn(%__MODULE__{session_id: sid} = session, prompt, per_call_opts)
       when is_binary(sid) do
    exec_resume = build_exec_resume(session, prompt, per_call_opts)

    metadata = Telemetry.session_turn_metadata(:session_resume, exec_resume, session.session_id)

    Telemetry.span([:codex_wrapper, :session, :turn], metadata, fn ->
      exec_resume |> ExecResume.json() |> ExecResume.execute(session.config) |> turn_outcome()
    end)
  end

  defp build_exec(session, prompt, per_call_opts) do
    Options.exec(prompt, Keyword.merge(session.exec_opts, per_call_opts))
  end

  # First-turn-only options set on the session are skipped here; the same
  # options passed for this call raise in the mapper.
  defp build_exec_resume(session, prompt, per_call_opts) do
    session_opts = Keyword.drop(session.exec_opts, Options.first_turn_only())

    Options.exec_resume(
      session.session_id,
      prompt,
      Keyword.merge(session_opts, per_call_opts)
    )
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

  defp turn_outcome({:ok, %Result{exit_code: 0} = result}),
    do: {:ok, result, JsonLineEvent.parse_lines(result.stdout)}

  defp turn_outcome({:ok, %Result{exit_code: code} = result}),
    do: {:error, {:exit, code, result}}

  defp turn_outcome({:error, _} = error), do: error

  # A first turn adopts the reported thread. A resumed turn keeps its id when
  # the turn reports none or the same one. A session resumed by name adopts
  # the UUID codex reports; one resumed by UUID refuses a different id.
  defp next_session_id(current, events, result) do
    case {current, extract_session_id(events)} do
      {current, nil} -> {:ok, current}
      {nil, reported} -> {:ok, reported}
      {same, same} -> {:ok, same}
      {current, reported} -> resumed_id(current, reported, result)
    end
  end

  defp resumed_id(current, reported, result) do
    if uuid?(current),
      do: {:error, {:thread_mismatch, current, reported, result}},
      else: {:ok, reported}
  end

  defp uuid?(id),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, id)

  # Public with @doc false so the session-id-capture logic can be covered
  # by regression tests -- see SessionTest `describe "extract_session_id/1"`.
  # Only a `thread.started` event with a non-blank binary `thread_id` names
  # the thread (codex 0.119+), the same rule the observed execution path
  # applies through `SessionObservation.parse/1`.
  @doc false
  @spec extract_session_id([JsonLineEvent.t()]) :: String.t() | nil
  def extract_session_id(events) do
    Enum.find_value(events, fn
      %JsonLineEvent{event_type: "thread.started"} = event ->
        thread_id(JsonLineEvent.get(event, "thread_id"))

      _event ->
        nil
    end)
  end

  defp thread_id(id) when is_binary(id), do: if(String.trim(id) != "", do: id)
  defp thread_id(_id), do: nil
end
