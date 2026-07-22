defmodule CodexWrapper.Telemetry do
  @moduledoc """
  Telemetry instrumentation for the Codex CLI wrapper.

  Emits `:telemetry` span events (`:start`, `:stop`, `:exception`) around
  the core exec paths so host applications can observe durations, metadata,
  and failures without re-implementing instrumentation.

  ## Events

    * `[:codex_wrapper, :exec, :start | :stop | :exception]`
      -- emitted around `CodexWrapper.Exec.execute/2` and
      `CodexWrapper.Exec.execute_json/2`.
    * `[:codex_wrapper, :stream, :start | :stop | :exception]`
      -- emitted around the port setup for `CodexWrapper.Exec.stream/2`
      and `CodexWrapper.ExecResume.stream/2`.
    * `[:codex_wrapper, :review, :start | :stop | :exception]`
      -- emitted around `CodexWrapper.Review.execute/2` and
      `CodexWrapper.Review.execute_json/2`.
    * `[:codex_wrapper, :session, :turn, :start | :stop | :exception]`
      -- emitted around each `CodexWrapper.Session.send/3` turn (wraps
      Exec, ExecResume, and Fork dispatch).

  ## Measurements

  Standard span measurements emitted by `:telemetry.span/3`:

    * `:start` -- `%{monotonic_time: integer(), system_time: integer()}`
    * `:stop` -- `%{monotonic_time: integer(), duration: integer()}`
    * `:exception` -- `%{monotonic_time: integer(), duration: integer()}`

  ## Metadata

  Start metadata includes (when available):

    * `:command` -- atom identifying the command path (e.g. `:exec`,
      `:exec_json`, `:exec_stream`, `:review`, `:review_json`,
      `:review_stream`, `:exec_resume_stream`, `:session_exec`,
      `:session_resume`, `:session_fork`)
    * `:session_id` -- session identifier when present
    * `:sandbox_mode` -- sandbox mode atom from the builder
    * `:approval_policy` -- approval policy atom from the builder

  Stop metadata adds:

    * `:exit_code` -- non-negative integer from the subprocess (when
      the call resolves to a `%CodexWrapper.Result{}`)

  Exception metadata adds the `:kind`, `:reason`, and `:stacktrace`
  fields populated by `:telemetry.span/3`.

  ## Attaching a handler

      :telemetry.attach_many(
        "codex-wrapper-logger",
        [
          [:codex_wrapper, :exec, :stop],
          [:codex_wrapper, :stream, :stop],
          [:codex_wrapper, :review, :stop],
          [:codex_wrapper, :session, :turn, :stop]
        ],
        fn event, measurements, metadata, _config ->
          IO.inspect({event, measurements, metadata})
        end,
        nil
      )
  """

  @type event_name :: [atom(), ...]
  @type metadata :: map()

  @doc """
  Wrap a function call with a `:telemetry.span/3` using the given event
  prefix and metadata.

  The wrapped function must return either:

    * `{:ok, %CodexWrapper.Result{}}` -- `exit_code` is added to stop metadata
    * `{:ok, term()}` or `{:error, term()}` -- no `exit_code` derived
    * any other term -- passed through

  The telemetry span returns the function's result untouched, so callers
  can wrap existing code paths without changing semantics.
  """
  @spec span(event_name(), metadata(), (-> result)) :: result when result: var
  def span(event_prefix, start_metadata, fun)
      when is_list(event_prefix) and is_map(start_metadata) and is_function(fun, 0) do
    :telemetry.span(event_prefix, start_metadata, fn ->
      result = fun.()
      {result, stop_metadata(start_metadata, result)}
    end)
  end

  @doc """
  Build start metadata for an Exec-style builder (Exec, ExecResume, Fork).

  Extracts the common fields -- `command`, `session_id` (when present),
  `sandbox_mode`, and `approval_policy` -- from the builder struct.
  """
  @spec exec_metadata(atom(), struct()) :: metadata()
  def exec_metadata(command, %{} = builder) when is_atom(command) do
    %{
      command: command,
      session_id: Map.get(builder, :session_id),
      sandbox_mode: Map.get(builder, :sandbox),
      approval_policy: Map.get(builder, :approval_policy)
    }
  end

  @doc """
  Build start metadata for a Review command.

  Review has no sandbox or approval policy of its own, so those fields
  are `nil`.
  """
  @spec review_metadata(atom(), struct()) :: metadata()
  def review_metadata(command, %{}) when is_atom(command) do
    %{
      command: command,
      session_id: nil,
      sandbox_mode: nil,
      approval_policy: nil
    }
  end

  @doc """
  Build start metadata for a session turn.

  `command` is one of `:session_exec`, `:session_resume`, or `:session_fork`.
  """
  @spec session_turn_metadata(atom(), struct(), String.t() | nil) :: metadata()
  def session_turn_metadata(command, %{} = builder, session_id) when is_atom(command) do
    %{
      command: command,
      session_id: session_id || Map.get(builder, :session_id),
      sandbox_mode: Map.get(builder, :sandbox),
      approval_policy: Map.get(builder, :approval_policy)
    }
  end

  # --- Private ---

  defp stop_metadata(start_metadata, {:ok, %CodexWrapper.Result{exit_code: code}}) do
    Map.put(start_metadata, :exit_code, code)
  end

  defp stop_metadata(start_metadata, {:ok, %CodexWrapper.Result{exit_code: code}, _extra}) do
    Map.put(start_metadata, :exit_code, code)
  end

  defp stop_metadata(start_metadata, _other), do: start_metadata
end
