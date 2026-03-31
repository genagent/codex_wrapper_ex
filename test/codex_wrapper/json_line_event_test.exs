defmodule CodexWrapper.JsonLineEventTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.JsonLineEvent

  describe "parse/1" do
    test "parses a valid NDJSON line with type" do
      line = ~s({"type":"thread.started","thread_id":"abc123"})
      assert {:ok, event} = JsonLineEvent.parse(line)
      assert event.event_type == "thread.started"
      assert event.data["thread_id"] == "abc123"
      assert event.raw == line
    end

    test "parses a line without type field" do
      line = ~s({"foo":"bar"})
      assert {:ok, event} = JsonLineEvent.parse(line)
      assert event.event_type == nil
      assert event.data["foo"] == "bar"
    end

    test "returns error for non-object JSON" do
      assert {:error, :not_an_object} = JsonLineEvent.parse("[1,2,3]")
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode, _}} = JsonLineEvent.parse("not json")
    end

    test "parses multiple event types" do
      lines = [
        ~s({"type":"thread.started","thread_id":"t1"}),
        ~s({"type":"turn.started","turn_id":"u1"}),
        ~s({"type":"item.completed","item":{"id":"i1"}}),
        ~s({"type":"turn.completed","turn_id":"u1"})
      ]

      events =
        Enum.map(lines, fn line ->
          {:ok, event} = JsonLineEvent.parse(line)
          event
        end)

      assert Enum.map(events, & &1.event_type) == [
               "thread.started",
               "turn.started",
               "item.completed",
               "turn.completed"
             ]
    end
  end

  describe "accessor functions" do
    setup do
      line = ~s({"type":"item.completed","item":{"id":"i1"},"session_id":"s1"})
      {:ok, event} = JsonLineEvent.parse(line)
      %{event: event}
    end

    test "event_type/1", %{event: event} do
      assert JsonLineEvent.event_type(event) == "item.completed"
    end

    test "data/1", %{event: event} do
      data = JsonLineEvent.data(event)
      assert data["type"] == "item.completed"
      assert data["session_id"] == "s1"
    end

    test "get/2 returns value for existing key", %{event: event} do
      assert JsonLineEvent.get(event, "session_id") == "s1"
    end

    test "get/2 returns nil for missing key", %{event: event} do
      assert JsonLineEvent.get(event, "missing") == nil
    end

    test "get/3 returns default for missing key", %{event: event} do
      assert JsonLineEvent.get(event, "missing", "default") == "default"
    end

    test "type?/2 returns true for matching type", %{event: event} do
      assert JsonLineEvent.type?(event, "item.completed")
    end

    test "type?/2 returns false for non-matching type", %{event: event} do
      refute JsonLineEvent.type?(event, "turn.started")
    end
  end
end
