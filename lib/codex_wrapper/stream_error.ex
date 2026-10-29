defmodule CodexWrapper.StreamError do
  @moduledoc """
  A terminal failure emitted by a streaming Codex command.

  `{:idle_timeout, ms}` means no output arrived within the configured idle
  interval; `{:timeout, ms}` means the whole command exceeded its deadline;
  `{:line_too_long, max_bytes}` means a JSONL line exceeded the runner's
  supported size and could not be parsed safely; `{:exit_status, code}`
  means codex exited nonzero (127 when the executable was not found on
  `Runner.Port`); `{:spawn, reason}` means it could not be started;
  `{:signal, signal}` means `Runner.Forcola` reported death by signal.
  """

  @type t :: %__MODULE__{reason: term()}
  defstruct [:reason]
end
