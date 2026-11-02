defmodule CodexWrapper.TurnTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{JsonLineEvent, Result, Turn}

  @fixtures Path.expand("../fixtures/turns", __DIR__)
  @fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_input_tokens,
    :output_tokens,
    :reasoning_output_tokens
  ]

  defp result(events, code \\ 0) do
    Result.from_cmd({Enum.map_join(events, "\n", &Jason.encode!/1), code})
  end

  defp event(type, data \\ %{}), do: Map.put(data, "type", type)

  defp message(text, type \\ "item.completed") do
    event(type, %{"item" => %{"type" => "agent_message", "text" => text}})
  end

  test "projects the synthetic 0.165.0 fixture without changing the raw result" do
    stdout = File.read!(Path.join(@fixtures, "0.165.0-completed.ndjson"))
    result = Result.from_cmd({stdout, 0})
    turn = Turn.from_result(result)

    assert %Turn{
             status: :completed,
             exit_code: 0,
             thread_id: "019b1e96-6935-7a02-a61e-325504b0b832",
             final_message: "done",
             error: nil,
             usage: %{
               input_tokens: 120,
               cached_input_tokens: 100,
               cache_write_input_tokens: 0,
               output_tokens: 7,
               reasoning_output_tokens: 3
             }
           } = turn

    assert turn.events == JsonLineEvent.parse_lines(stdout)
    assert turn.terminal_event == List.last(turn.events)
    assert turn.terminal_event.data["usage"]["future_tokens"] == 99
    refute Map.has_key?(turn.usage, :future_tokens)
    assert result == %Result{stdout: stdout, stderr: "", exit_code: 0, success: true}
  end

  test "status follows terminal and error order, with nonzero exit overriding completion" do
    completed = event("turn.completed")
    failed = event("turn.failed", %{"error" => %{"message" => "failed"}})
    error = event("error", %{"message" => "stream error"})

    for {events, code, status, native_error} <- [
          {[], 0, :no_terminal, nil},
          {[], 2, :failed, nil},
          {[completed], 0, :completed, nil},
          {[completed], 2, :failed, nil},
          {[failed], 0, :failed, failed["error"]},
          {[failed], 2, :failed, failed["error"]},
          {[failed, completed], 0, :completed, nil},
          {[completed, failed], 0, :failed, failed["error"]},
          {[error], 0, :failed, error},
          {[error, completed], 0, :completed, nil},
          {[completed, error], 0, :failed, error},
          {[completed, error], 2, :failed, error},
          {[completed, error, completed], 0, :completed, nil},
          {[error, failed], 0, :failed, failed["error"]}
        ] do
      turn = Turn.from_result(result(events, code))
      assert turn.status == status, inspect({events, code})
      assert turn.error == native_error
      assert turn.exit_code == code
    end
  end

  test "uses exit_code even when the Result.success flag disagrees" do
    assert %Turn{status: :failed} =
             Turn.from_result(%{result([event("turn.completed")], 1) | success: true})

    assert %Turn{status: :completed} =
             Turn.from_result(%{result([event("turn.completed")]) | success: false})
  end

  test "a failed event without native error data is still failed" do
    assert %Turn{status: :failed, error: nil, terminal_event: %JsonLineEvent{}} =
             Turn.from_result(result([event("turn.failed")]))
  end

  test "uses the last completed agent message from the last turn" do
    events = [
      event("turn.started"),
      message("previous turn"),
      event("turn.completed"),
      event("turn.started"),
      message("draft"),
      event("item.completed", %{"item" => %{"type" => "reasoning", "text" => "thinking"}}),
      message("final"),
      message("not completed", "item.updated"),
      event("turn.completed")
    ]

    turn = Turn.from_result(result(events))
    assert turn.final_message == "final"
    assert length(turn.events) == length(events)
    assert Turn.from_result(result(events ++ [event("turn.started")])).final_message == nil
  end

  test "a new turn clears its message and usage but retains the stream's reported outcome" do
    usage = %{"input_tokens" => 12, "output_tokens" => 3}
    error = %{"message" => "earlier failure"}

    for {outcome, status, native_error} <- [
          {event("turn.completed", %{"usage" => usage}), :completed, nil},
          {event("turn.failed", %{"error" => error, "usage" => usage}), :failed, error}
        ] do
      events = [
        event("thread.started", %{"thread_id" => "native-thread"}),
        event("turn.started"),
        message("earlier answer"),
        outcome,
        event("turn.started")
      ]

      turn = Turn.from_result(result(events))
      assert turn.status == status
      assert turn.error == native_error
      assert turn.terminal_event.data == outcome
      assert turn.final_message == nil
      assert turn.usage == nil
      assert turn.thread_id == "native-thread"
      assert turn.events == JsonLineEvent.parse_lines(result(events).stdout)

      failed_process = Turn.from_result(result(events, 7))
      assert failed_process.status == :failed
      assert failed_process.exit_code == 7
      assert failed_process.terminal_event == turn.terminal_event
      assert failed_process.error == native_error
    end
  end

  test "a new turn retains a preceding top-level error until a terminal supersedes it" do
    error = event("error", %{"message" => "earlier stream failure"})
    events = [event("turn.completed"), error, event("turn.started")]
    turn = Turn.from_result(result(events))

    assert turn.status == :failed
    assert turn.error == error
    assert turn.terminal_event.event_type == "turn.completed"
    assert turn.final_message == nil
    assert turn.usage == nil

    recovered = Turn.from_result(result(events ++ [event("turn.completed")]))
    assert recovered.status == :completed
    assert recovered.error == nil
  end

  test "missing turn.started is allowed, and malformed final message does not reuse earlier text" do
    assert Turn.from_result(result([message("hello")])).final_message == "hello"

    for text <- [nil, 123, %{}, []] do
      assert Turn.from_result(result([message("earlier"), message(text)])).final_message == nil
    end

    assert Turn.from_result(result([message("")])).final_message == ""

    assert Turn.from_result(result([event("item.completed", %{"item" => nil})])).final_message ==
             nil
  end

  test "thread identity uses the first nonblank string on thread.started only" do
    events = [
      event("result", %{"session_id" => "legacy"}),
      event("item.completed", %{"thread_id" => "wrong"}),
      event("thread.started", %{"thread_id" => 7}),
      event("thread.started", %{"thread_id" => " \t"}),
      event("thread.started", %{"thread_id" => "native"}),
      event("thread.started", %{"thread_id" => "later"})
    ]

    assert Turn.from_result(result(events)).thread_id == "native"
    assert Turn.from_result(result([])).thread_id == nil
  end

  test "invalid synthetic usage remains in raw events but becomes nil in the projection" do
    stdout = File.read!(Path.join(@fixtures, "0.165.0-invalid-usage.ndjson"))
    turn = Turn.from_result(Result.from_cmd({stdout, 0}))
    assert turn.usage == Map.new(@fields, &{&1, nil})
    assert turn.terminal_event.data["usage"]["input_tokens"] == -1
    assert turn.terminal_event.data["usage"]["cached_input_tokens"] == "100"
    assert turn.terminal_event.data["usage"]["cache_write_input_tokens"] == 1.5
    assert turn.terminal_event.data["usage"]["output_tokens"] == true
    assert turn.terminal_event.data["usage"]["future_tokens"] == 99
  end

  test "every known usage field accepts only nonnegative integers" do
    for field <- @fields, value <- [0, 9, -1, 1.0, "9", true, false, nil, [], %{}] do
      usage = %{Atom.to_string(field) => value}
      turn = Turn.from_result(result([event("turn.completed", %{"usage" => usage})]))
      expected = if is_integer(value) and value >= 0, do: value
      assert turn.usage[field] == expected
      assert Map.keys(turn.usage) |> Enum.sort() == Enum.sort(@fields)
    end
  end

  test "absent or malformed usage is unknown, and never leaks across turns or terminals" do
    first = event("turn.completed", %{"usage" => %{"input_tokens" => 5}})

    for usage <- [nil, [], 0, "unknown"] do
      assert Turn.from_result(result([event("turn.completed", %{"usage" => usage})])).usage == nil
    end

    assert Turn.from_result(result([first, event("turn.started")])).usage == nil
    assert Turn.from_result(result([first, event("turn.failed")])).usage == nil
    assert Turn.from_result(result([first, event("turn.completed")])).usage == nil

    assert Turn.from_result(result([event("turn.completed", %{"usage" => %{}})])).usage ==
             Map.new(@fields, &{&1, nil})
  end

  test "partial events project without inventing an exit code" do
    events = JsonLineEvent.parse_lines(~s({"type":"turn.completed"}))
    assert %Turn{status: :completed, exit_code: nil} = Turn.from_events(events)
    assert %Turn{status: :failed, exit_code: 3} = Turn.from_events(events, 3)
    assert %Turn{status: :no_terminal, exit_code: nil} = Turn.from_events([])
  end

  test "noise, malformed JSON and unknown event types do not obscure valid events" do
    stdout =
      "diagnostic\n{invalid\n[]\n" <> result([message("done"), event("turn.completed")]).stdout

    turn = Turn.from_result(Result.from_cmd({stdout, 0}))
    assert turn.status == :completed
    assert turn.final_message == "done"
    assert length(turn.events) == 2

    unknown = event("future.event", %{"new_field" => 123})
    turn = Turn.from_result(result([unknown]))
    assert turn.status == :no_terminal
    assert hd(turn.events).data == unknown
  end
end
