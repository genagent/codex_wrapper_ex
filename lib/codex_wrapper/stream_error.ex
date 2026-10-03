defmodule CodexWrapper.StreamError do
  @moduledoc """
  A terminal failure emitted by a streaming Codex command.

  `{:idle_timeout, ms}` means no output arrived within the configured idle
  interval; `{:timeout, ms}` means the whole command exceeded its deadline.
  """

  @type t :: %__MODULE__{reason: term()}
  defstruct [:reason]
end
