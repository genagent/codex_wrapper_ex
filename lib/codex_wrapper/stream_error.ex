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
  `{:argument_list_too_long, details}` means the argument list or environment
  exceeded the pre-spawn size bound; details contain sizes without contents.
  `{:invalid_argument, index}` identifies an argument containing NUL.
  `{:stdin_file, reason}` means prompt-file preparation failed.
  """

  @type t :: %__MODULE__{reason: term()}
  defstruct [:reason]
end
