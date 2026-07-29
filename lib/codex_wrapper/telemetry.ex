defmodule CodexWrapper.Telemetry.Stream do
  @moduledoc false

  @enforce_keys [:event_prefix, :metadata, :stream_fun]
  defstruct [:event_prefix, :metadata, :stream_fun]

  @type t :: %__MODULE__{
          event_prefix: [atom(), ...],
          metadata: map(),
          stream_fun: (-> Enumerable.t())
        }

  @doc false
  @spec reduce(t(), term(), (term(), term() -> term())) :: term()
  def reduce(%__MODULE__{} = stream, accumulator, reducer) do
    started_at = System.monotonic_time()

    :telemetry.execute(
      stream.event_prefix ++ [:start],
      %{monotonic_time: started_at, system_time: System.system_time()},
      stream.metadata
    )

    continuation = fn next_accumulator ->
      stream.stream_fun.()
      |> Enumerable.reduce(next_accumulator, reducer)
    end

    continue(
      continuation,
      accumulator,
      stream.event_prefix,
      stream.metadata,
      started_at
    )
  end

  defp continue(continuation, accumulator, event_prefix, metadata, started_at) do
    case continuation.(accumulator) do
      {:done, _value} = result ->
        emit_stop(event_prefix, metadata, started_at)
        result

      {:halted, _value} = result ->
        emit_stop(event_prefix, metadata, started_at)
        result

      {:suspended, value, next_continuation} ->
        wrapped_continuation = fn next_accumulator ->
          continue(next_continuation, next_accumulator, event_prefix, metadata, started_at)
        end

        {:suspended, value, wrapped_continuation}
    end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      emit_exception(event_prefix, metadata, started_at, kind, reason, stacktrace)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp emit_stop(event_prefix, metadata, started_at) do
    stopped_at = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:stop],
      %{monotonic_time: stopped_at, duration: stopped_at - started_at},
      metadata
    )
  end

  defp emit_exception(event_prefix, metadata, started_at, kind, reason, stacktrace) do
    stopped_at = System.monotonic_time()

    exception_metadata =
      metadata
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)
      |> Map.put(:stacktrace, stacktrace)

    :telemetry.execute(
      event_prefix ++ [:exception],
      %{monotonic_time: stopped_at, duration: stopped_at - started_at},
      exception_metadata
    )
  end
end

defimpl Enumerable, for: CodexWrapper.Telemetry.Stream do
  alias CodexWrapper.Telemetry.Stream

  @spec reduce(Stream.t(), term(), (term(), term() -> term())) :: term()
  def reduce(stream, accumulator, reducer), do: Stream.reduce(stream, accumulator, reducer)

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end

defmodule CodexWrapper.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by CodexWrapper.

  The synchronous command and session events use `:telemetry.span/3`.
  Streaming events follow the same start/stop/exception convention while
  keeping the span open for the lifetime of lazy enumeration.

  ## Events

    * `[:codex_wrapper, :exec, :start | :stop | :exception]` — emitted
      around `CodexWrapper.Exec.execute/2` and
      `CodexWrapper.ExecResume.execute/2`.
    * `[:codex_wrapper, :stream, :start | :stop | :exception]` — emitted
      while consuming streams returned by `CodexWrapper.Exec.stream/2`,
      `CodexWrapper.ExecResume.stream/2`, and
      `CodexWrapper.Review.stream/2`. Start is emitted on first reduction;
      stop is emitted on producer exhaustion or an early consumer halt.
    * `[:codex_wrapper, :review, :start | :stop | :exception]` — emitted
      around `CodexWrapper.Review.execute/2`.
    * `[:codex_wrapper, :session, :turn, :start | :stop | :exception]` —
      emitted around each synchronous `CodexWrapper.Session.send/3` turn.

  `execute_json/2` uses the corresponding `execute/2` path and therefore
  emits the same exec or review event rather than a second JSON-specific
  event.

  ## Measurements

    * `:start` — `%{monotonic_time: integer(), system_time: integer()}`
    * `:stop` — `%{monotonic_time: integer(), duration: integer()}`
    * `:exception` — `%{monotonic_time: integer(), duration: integer()}`

  ## Metadata

  Every event includes:

    * `:command` — one of `:exec`, `:exec_resume`, `:review`,
      `:session_exec`, or `:session_resume`
    * `:session_id` — the session identifier when known
    * `:sandbox_mode` — the configured sandbox mode when present
    * `:approval_policy` — the configured approval policy when present

  Synchronous stop events additionally include `:exit_code` when the
  wrapped call returns a `%CodexWrapper.Result{}`. Stream events do not
  include an exit code because the lazy Runner contract does not expose
  one. Exception metadata follows the standard span shape with `:kind`,
  `:reason`, and `:stacktrace`.

  ## Example

      :telemetry.attach_many(
        "codex-wrapper-logger",
        [
          [:codex_wrapper, :exec, :stop],
          [:codex_wrapper, :stream, :stop],
          [:codex_wrapper, :review, :stop],
          [:codex_wrapper, :session, :turn, :stop]
        ],
        fn event, measurements, metadata, _config ->
          require Logger

          Logger.info(
            "\#{inspect(event)} duration=\#{measurements.duration} " <>
              "metadata=\#{inspect(metadata)}"
          )
        end,
        nil
      )
  """

  alias CodexWrapper.Result
  alias CodexWrapper.Telemetry.Stream, as: TelemetryStream

  @type event_name :: [atom(), ...]
  @type metadata :: %{optional(atom()) => term()}

  @doc """
  Run a synchronous function inside a telemetry span.

  The function's return value is preserved. When it contains a
  `%CodexWrapper.Result{}`, its exit code is added to stop metadata.
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
  Instrument the full lifecycle of a lazy enumerable.

  No event is emitted and `stream_fun` is not called until the returned
  enumerable is first reduced. The stop event is emitted after the producer
  finishes or the consumer halts it. Producer and consumer exceptions emit
  an exception event and are re-raised without a stop event.
  """
  @spec span_stream(event_name(), metadata(), (-> Enumerable.t())) :: Enumerable.t()
  def span_stream(event_prefix, start_metadata, stream_fun)
      when is_list(event_prefix) and is_map(start_metadata) and is_function(stream_fun, 0) do
    %TelemetryStream{
      event_prefix: event_prefix,
      metadata: start_metadata,
      stream_fun: stream_fun
    }
  end

  @doc """
  Build metadata for an Exec or ExecResume command.
  """
  @spec exec_metadata(atom(), struct()) :: metadata()
  def exec_metadata(command, %{} = builder) when is_atom(command) do
    command_metadata(command, builder)
  end

  @doc """
  Build metadata for a Review command.
  """
  @spec review_metadata(atom(), struct()) :: metadata()
  def review_metadata(command, %{} = builder) when is_atom(command) do
    command_metadata(command, builder)
  end

  @doc """
  Build metadata for a session turn.
  """
  @spec session_turn_metadata(atom(), struct(), String.t() | nil) :: metadata()
  def session_turn_metadata(command, %{} = builder, session_id) when is_atom(command) do
    command
    |> command_metadata(builder)
    |> Map.put(:session_id, session_id || Map.get(builder, :session_id))
  end

  defp command_metadata(command, builder) do
    %{
      command: command,
      session_id: Map.get(builder, :session_id),
      sandbox_mode: Map.get(builder, :sandbox),
      approval_policy: Map.get(builder, :approval_policy)
    }
  end

  defp stop_metadata(start_metadata, {:ok, %Result{exit_code: code}}) do
    Map.put(start_metadata, :exit_code, code)
  end

  defp stop_metadata(start_metadata, {:ok, %Result{exit_code: code}, _extra}) do
    Map.put(start_metadata, :exit_code, code)
  end

  defp stop_metadata(start_metadata, _other), do: start_metadata
end
