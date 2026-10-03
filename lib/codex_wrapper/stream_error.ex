defmodule CodexWrapper.StreamError do
  @moduledoc """
  A terminal failure emitted by a streaming Codex command.

  `{:idle_timeout, ms}` means no output arrived within the configured idle
  interval; `{:timeout, ms}` means the whole command exceeded its deadline;
  `{:line_too_long, max_bytes}` means a JSONL line exceeded the runner's
  supported size and could not be parsed safely.
  """

  @type t :: %__MODULE__{reason: term()}
  defstruct [:reason]
end
