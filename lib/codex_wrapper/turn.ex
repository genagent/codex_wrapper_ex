defmodule CodexWrapper.Turn do
  @moduledoc """
  A pure projection of a command's `--json` output, which can contain several turns.

  `from_result/1` starts no process and leaves the raw `CodexWrapper.Result`
  unchanged. Ordinary text messages do not need to contain JSON:

      {:ok, result} = CodexWrapper.exec("Summarize the project", json: true)
      turn = CodexWrapper.Turn.from_result(result)
      turn.final_message

  ## Field scopes

  `status`, `error`, and `terminal_event` summarize the **entire event stream**.
  The last `turn.completed` or `turn.failed` determines the native outcome;
  a top-level `error` fails it until a later terminal event supersedes that
  error. A new `turn.started` does not clear these three fields. Therefore
  `:completed` means the stream's last reported terminal outcome completed,
  not that its last started turn necessarily finished. `:no_terminal` means
  no terminal event or error was reported anywhere in the stream, provided
  the process did not exit nonzero.

  `exit_code` describes the whole process. A nonzero exit always makes
  `status` `:failed`, including after `turn.completed`. `error` retains native
  error data or `nil`; process failure alone does not fabricate an error
  object. `terminal_event` remains the last native terminal event regardless
  of process exit or subsequent top-level errors. `thread_id` is the first
  nonblank string ID announced by `thread.started` anywhere in the stream.
  `events` keeps every parsed event, including unknown fields and invalid
  usage values.

  `final_message` and `usage` describe only the **last started turn**. Both
  reset to `nil` at each `turn.started`. The message is its last completed
  `agent_message` text, and usage comes from its last terminal event. If no
  `turn.started` appears, these fields use the whole stream. Only the five
  documented token fields are projected, each as a nonnegative integer or
  `nil`; missing usage is `nil`, not zero.

  For example, `turn.started`, `turn.completed`, `turn.started` produces
  `status: :completed` and retains the earlier `terminal_event`, while
  `final_message` and `usage` are `nil`. The new turn has no reported outcome.
  """

  alias CodexWrapper.{JsonLineEvent, Result}

  @usage_fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_input_tokens,
    :output_tokens,
    :reasoning_output_tokens
  ]

  @type usage :: %{
          input_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          cache_write_input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          reasoning_output_tokens: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          status: :completed | :failed | :no_terminal,
          exit_code: non_neg_integer() | nil,
          thread_id: String.t() | nil,
          final_message: String.t() | nil,
          usage: usage() | nil,
          error: term(),
          events: [JsonLineEvent.t()],
          terminal_event: JsonLineEvent.t() | nil
        }

  defstruct [
    :exit_code,
    :thread_id,
    :final_message,
    :usage,
    :error,
    :terminal_event,
    status: :no_terminal,
    events: []
  ]

  @doc """
  Project a completed command result without starting a process.

  The command must have requested `--json`. Non-JSON lines are ignored by
  `CodexWrapper.JsonLineEvent.parse_lines/1` and remain in the original result.
  """
  @spec from_result(Result.t()) :: t()
  def from_result(%Result{} = result) do
    result.stdout
    |> JsonLineEvent.parse_lines()
    |> from_events(result.exit_code)
  end

  @doc """
  Project already parsed events, optionally with a known process exit code.

  With the default `nil` exit code, status describes only the native events;
  it does not establish that a process exited successfully.
  """
  @spec from_events([JsonLineEvent.t()], non_neg_integer() | nil) :: t()
  def from_events(events, exit_code \\ nil) do
    turn = Enum.reduce(events, %__MODULE__{events: events, exit_code: exit_code}, &project/2)

    if is_integer(exit_code) and exit_code != 0,
      do: %{turn | status: :failed},
      else: turn
  end

  defp project(%JsonLineEvent{event_type: "thread.started", data: data}, turn) do
    %{turn | thread_id: turn.thread_id || thread_id(data["thread_id"])}
  end

  defp project(%JsonLineEvent{event_type: "turn.started"}, turn),
    do: %{turn | final_message: nil, usage: nil}

  defp project(
         %JsonLineEvent{
           event_type: "item.completed",
           data: %{"item" => %{"type" => "agent_message"} = item}
         },
         turn
       ) do
    text = if is_binary(item["text"]), do: item["text"]
    %{turn | final_message: text}
  end

  defp project(%JsonLineEvent{event_type: "turn.completed", data: data} = event, turn),
    do: %{
      turn
      | status: :completed,
        error: nil,
        usage: usage(data["usage"]),
        terminal_event: event
    }

  defp project(%JsonLineEvent{event_type: "turn.failed", data: data} = event, turn),
    do: %{
      turn
      | status: :failed,
        error: data["error"],
        usage: usage(data["usage"]),
        terminal_event: event
    }

  defp project(%JsonLineEvent{event_type: "error", data: data}, turn),
    do: %{turn | status: :failed, error: data}

  defp project(_event, turn), do: turn

  defp thread_id(id) when is_binary(id), do: if(String.trim(id) != "", do: id)
  defp thread_id(_id), do: nil

  defp usage(data) when is_map(data) do
    Map.new(@usage_fields, fn field ->
      value = data[Atom.to_string(field)]
      {field, if(is_integer(value) and value >= 0, do: value)}
    end)
  end

  defp usage(_data), do: nil
end
