defmodule CodexWrapper.SessionObservation do
  @moduledoc """
  A native thread identity announced during observed one-shot execution.

  The execution caller sends `{reference, observation}` to the local observer
  before returning. This is identity evidence, not successful completion.
  Callers own persistence and must reject stale invocation references.
  """

  @max_line_bytes 1_048_576

  @type t :: %__MODULE__{session_id: String.t(), source: :thread_started}
  @enforce_keys [:session_id]
  defstruct [:session_id, source: :thread_started]

  @doc false
  @spec parse(binary()) :: t() | nil
  def parse(line) when byte_size(line) <= @max_line_bytes do
    case Jason.decode(line) do
      {:ok, %{"type" => "thread.started", "thread_id" => id}} when is_binary(id) ->
        if String.trim(id) != "", do: %__MODULE__{session_id: id}

      _other ->
        nil
    end
  end

  def parse(_line), do: nil

  @doc false
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes
end
