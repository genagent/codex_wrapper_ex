defmodule CodexWrapper.UnsupportedError do
  @moduledoc """
  Raised when the installed Codex CLI lacks a capability a lazy stream needs.

  Synchronous calls return `{:error, {:unsupported, capability}}` instead.
  A stream has no error tuple to return, so it raises this while it is
  being enumerated. `capability` is the same atom the tuple carries, for
  example `:exec_fork`.
  """

  defexception [:capability]

  @type t :: %__MODULE__{capability: atom()}

  @impl true
  def message(%__MODULE__{capability: capability}),
    do: "the installed codex CLI does not support #{inspect(capability)}"
end
