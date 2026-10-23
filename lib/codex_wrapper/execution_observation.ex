defmodule CodexWrapper.ExecutionObservation do
  @moduledoc """
  One correlated terminal fact from an evidenced one-shot execution.

  Sent as `{reference, observation}` by the execution caller before returning.
  A preceding `SessionObservation` establishes identity only. `:outcome` is the
  legacy execution result before JSON/fork convenience projections; `:parsed_result` is the last bounded native
  `turn.completed` or `turn.failed` JSON object, independent of process outcome.

  `:child_status` and `:child_signal` are raw native reports, never inferred
  from JSON, transport closure, or a pre-spawn failure. `:termination` records
  protocol/transport termination, while `:reason` records timeout or limit
  cancellation. `:cleanup`, `:scope`, and `:guard_close` are separate facts;
  missing facts remain `:unknown` (missing child status/signal remains `nil`).
  Process-group confirmation does not cover descendants escaping that group.
  `:stdout` and `:stderr` are bounded prefixes, including on failure.
  """

  @type t :: %__MODULE__{
          outcome: term(),
          stdout: binary(),
          stderr: binary(),
          parsed_result: map() | nil,
          child_status: non_neg_integer() | nil,
          child_signal: pos_integer() | nil,
          termination: term(),
          reason: term(),
          output_truncated: boolean() | :unknown,
          cleanup: :confirmed | :unconfirmed | :unknown,
          scope: :process_group | :active_cgroup | :unknown,
          guard_close: term()
        }
  defstruct [
    :outcome,
    :parsed_result,
    :child_status,
    :child_signal,
    stdout: "",
    stderr: "",
    termination: :unknown,
    reason: :unknown,
    output_truncated: :unknown,
    cleanup: :unknown,
    scope: :unknown,
    guard_close: :unknown
  ]
end
