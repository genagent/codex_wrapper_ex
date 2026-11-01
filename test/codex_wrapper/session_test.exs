defmodule CodexWrapper.SessionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{Config, JsonLineEvent, Result, Session}

  # Synthetic NDJSON supplied as the prompt makes each test's turn output
  # explicit while exercising the normal Session.send/3 recording path.
  defmodule UsageRunner do
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, opts, _timeout), do: {:ok, {Keyword.fetch!(opts, :stdin), 0}}
  end

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  defp usage_session do
    Session.new(Config.new(binary: "synthetic-codex", runner: UsageRunner))
  end

  defp record_usage(session, usage) do
    event = %{"type" => "turn.completed"}
    event = if usage == :missing, do: event, else: Map.put(event, "usage", usage)
    {:ok, session, _result} = Session.send(session, Jason.encode!(event))
    session
  end

  describe "new/2" do
    test "creates session with config" do
      config = Config.new()
      session = Session.new(config)
      assert session.config == config
      assert session.session_id == nil
      assert session.history == []
      assert session.last_turn == nil
      assert session.usage_total == nil
      assert session.exec_opts == []
    end

    test "with exec opts" do
      config = Config.new()
      session = Session.new(config, model: "o3", full_auto: true)
      assert session.exec_opts == [model: "o3", full_auto: true]
    end

    test "with a profile exec opt" do
      config = Config.new()
      session = Session.new(config, profile: "fast")
      assert session.exec_opts == [profile: "fast"]
    end
  end

  describe "resume/3" do
    test "sets session_id" do
      config = Config.new()
      session = Session.resume(config, "abc-123")
      assert Session.session_id(session) == "abc-123"
      assert Session.total_usage(session) == nil
    end

    test "with exec opts" do
      config = Config.new()
      session = Session.resume(config, "abc-123", model: "o3")
      assert session.exec_opts == [model: "o3"]
      assert Session.session_id(session) == "abc-123"
    end
  end

  describe "session_id/1" do
    test "returns nil when no session_id" do
      config = Config.new()
      session = Session.new(config)
      assert Session.session_id(session) == nil
    end

    test "returns session_id when set" do
      config = Config.new()
      session = Session.resume(config, "abc-123")
      assert Session.session_id(session) == "abc-123"
    end
  end

  describe "turn_count/1" do
    test "starts at zero" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turn_count(session) == 0
    end
  end

  describe "total_cost/1" do
    test "returns nil, since codex reports no cost" do
      config = Config.new()
      session = Session.new(config)
      assert Session.total_cost(session) == nil
    end
  end

  describe "last_result/1" do
    test "returns nil when no turns" do
      config = Config.new()
      session = Session.new(config)
      assert Session.last_result(session) == nil
    end
  end

  describe "last_turn/1" do
    test "returns nil before a turn is recorded" do
      assert Session.last_turn(Session.new(Config.new())) == nil
    end
  end

  describe "total_usage/1" do
    test "returns nil when there is no reported usage" do
      session = usage_session()
      assert Session.total_usage(session) == nil

      session = record_usage(session, :missing)
      assert Session.turn_count(session) == 1
      assert Session.total_usage(session) == nil
    end

    test "sums known counters while preserving unknown values and zero" do
      usages = [
        %{"input_tokens" => 12, "cached_input_tokens" => 0, "output_tokens" => 3},
        :missing,
        %{"input_tokens" => 5, "cache_write_input_tokens" => 2, "output_tokens" => -1},
        %{"input_tokens" => "9", "cached_input_tokens" => nil, "output_tokens" => 1.5},
        %{"reasoning_output_tokens" => false}
      ]

      session = Enum.reduce(usages, usage_session(), &record_usage(&2, &1))
      assert Session.turn_count(session) == length(usages)

      assert Session.total_usage(session) == %{
               input_tokens: 17,
               cached_input_tokens: 0,
               cache_write_input_tokens: 2,
               output_tokens: 3,
               reasoning_output_tokens: nil
             }
    end

    test "a reported empty usage map retains unknown counters" do
      session = record_usage(usage_session(), %{})

      assert Session.total_usage(session) == %{
               input_tokens: nil,
               cached_input_tokens: nil,
               cache_write_input_tokens: nil,
               output_tokens: nil,
               reasoning_output_tokens: nil
             }
    end

    test "repeated reads use recorded totals independently of raw stdout history" do
      session =
        usage_session()
        |> record_usage(%{"input_tokens" => 12, "output_tokens" => 0})
        |> record_usage(%{"input_tokens" => 5})

      expected = Session.total_usage(session)
      assert expected.input_tokens == 17
      assert expected.output_tokens == 0

      # A consumer may redact retained raw output after recording a turn.
      # Replaying these Results would lose the recorded usage entirely.
      history =
        Enum.map(session.history, fn %Result{} = result -> %{result | stdout: "redacted"} end)

      session = %{session | history: history}

      for _ <- 1..3, do: assert(Session.total_usage(session) == expected)
      assert Session.history(session) == history

      session = record_usage(session, %{"input_tokens" => 1, "cache_write_input_tokens" => 0})

      assert Session.total_usage(session) == %{
               expected
               | input_tokens: 18,
                 cache_write_input_tokens: 0
             }

      assert Enum.take(Session.history(session), 2) == history
    end
  end

  describe "turns/1" do
    test "returns empty list initially" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turns(session) == []
    end
  end

  describe "history/1" do
    test "aliases turns" do
      config = Config.new()
      session = Session.new(config)
      assert Session.history(session) == Session.turns(session)
    end
  end

  describe "extract_session_id/1" do
    test "extracts thread_id from a thread.started event" do
      events = [
        event("thread.started", %{"thread_id" => "019d799c-09f1-7ea0-8e5a-7b42a640c103"}),
        event("turn.started", %{}),
        event("turn.completed", %{"usage" => %{"input_tokens" => 10, "output_tokens" => 2}})
      ]

      assert Session.extract_session_id(events) == "019d799c-09f1-7ea0-8e5a-7b42a640c103"
    end

    test "ignores ids on events other than thread.started" do
      events = [
        event("result", %{"session_id" => "legacy-sid-123"}),
        event("item.completed", %{"thread_id" => "other"})
      ]

      assert Session.extract_session_id(events) == nil
    end

    test "ignores a blank or non-string thread_id" do
      assert Session.extract_session_id([event("thread.started", %{"thread_id" => " "})]) == nil
      assert Session.extract_session_id([event("thread.started", %{"thread_id" => 7})]) == nil
    end

    test "prefers thread_id when both are present" do
      events = [
        event("thread.started", %{
          "thread_id" => "new-thread",
          "session_id" => "old-sid"
        })
      ]

      assert Session.extract_session_id(events) == "new-thread"
    end

    test "returns nil when no thread.started event is present" do
      events = [
        event("turn.started", %{}),
        event("turn.completed", %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}})
      ]

      assert Session.extract_session_id(events) == nil
    end

    test "returns nil for an empty event list" do
      assert Session.extract_session_id([]) == nil
    end
  end

  describe "archive/1, unarchive/1, delete/2" do
    test "archive/1 archives the session id" do
      session = Session.resume(Config.new(binary: "echo"), "abc-123")
      assert {:ok, output} = Session.archive(session)
      assert output =~ "archive abc-123"
    end

    test "unarchive/1 unarchives the session id" do
      session = Session.resume(Config.new(binary: "echo"), "abc-123")
      assert {:ok, output} = Session.unarchive(session)
      assert output =~ "unarchive abc-123"
    end

    test "delete/2 requires confirm: true" do
      session = Session.resume(Config.new(binary: "echo"), "abc-123")
      assert Session.delete(session) == {:error, :confirmation_required}
      assert {:ok, output} = Session.delete(session, confirm: true)
      assert output =~ "delete abc-123"
    end

    test "all three refuse a session with no id yet" do
      session = Session.new(Config.new(binary: "false"))
      assert Session.archive(session) == {:error, :no_session}
      assert Session.unarchive(session) == {:error, :no_session}
      assert Session.delete(session, confirm: true) == {:error, :no_session}
    end
  end
end
