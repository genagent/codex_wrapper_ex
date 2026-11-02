defmodule CodexWrapper.SessionTurnTest do
  # Not async: attaches a global telemetry handler.
  use ExUnit.Case, async: false

  alias CodexWrapper.{Config, Result, Session, SessionServer, Turn}

  @moduletag :tmp_dir

  @uuid "019b1e96-6935-7a02-a61e-325504b0b832"
  @other "019b1e96-6935-7a02-a61e-000000000000"

  defp started(id), do: ~s({"type":"thread.started","thread_id":"#{id}"})

  # A fake codex that prints `stdout` lines, one `stderr` line, and exits
  # with `code`.
  defp fake(dir, stdout, stderr, code) do
    path = Path.join(dir, "fake_codex")
    out = Enum.map_join(stdout, "\n", &"printf '%s\\n' '#{&1}'")

    File.write!(path, """
    #!/bin/sh
    #{out}
    #{if stderr, do: "printf '%s\\n' '#{stderr}' >&2"}
    exit #{code}
    """)

    File.chmod!(path, 0o755)
    Config.new(binary: path, timeout: 10_000)
  end

  describe "a nonzero exit" do
    test "on a resumed turn returns the failure and leaves the session unchanged", %{
      tmp_dir: dir
    } do
      config = fake(dir, [], "Error: no rollout found for thread id #{@uuid}", 1)
      session = Session.resume(config, @uuid)

      assert {:error, {:exit, 1, %Result{exit_code: 1, success: false} = result}} =
               Session.send(session, "next")

      assert result.stdout =~ "no rollout found"
      assert Session.turn_count(session) == 0
      assert Session.session_id(session) == @uuid
    end

    test "with turn.failed on a new session returns the failure", %{tmp_dir: dir} do
      lines = [
        started(@uuid),
        ~s({"type":"turn.started"}),
        ~s({"type":"error","message":"boom"}),
        ~s({"type":"turn.failed","error":{"message":"boom"}})
      ]

      config = fake(dir, lines, nil, 1)

      assert {:error, {:exit, 1, %Result{success: false} = result}} =
               Session.send(Session.new(config), "first")

      assert result.stdout =~ "turn.failed"
    end

    test "reaches SessionServer.send_message/3", %{tmp_dir: dir} do
      config = fake(dir, [], "Error: boom", 1)
      {:ok, pid} = SessionServer.start_link(config: config)

      assert {:error, {:exit, 1, %Result{}}} = SessionServer.send_message(pid, "x")
      assert SessionServer.turn_count(pid) == 0
    end

    test "telemetry reports the real exit code", %{tmp_dir: dir} do
      config = fake(dir, [], "Error: boom", 1)
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "session-turn-#{inspect(ref)}",
        [:codex_wrapper, :session, :turn, :stop],
        fn _event, _measurements, metadata, _ -> send(parent, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("session-turn-#{inspect(ref)}") end)

      Session.send(Session.resume(config, @uuid), "x")
      assert_receive {^ref, %{exit_code: 1}}
    end
  end

  describe "a zero exit" do
    test "keeps the real output on the result and records the thread", %{tmp_dir: dir} do
      config = fake(dir, [started(@uuid), ~s({"type":"turn.completed"})], "a warning", 0)

      assert {:ok, session, %Result{exit_code: 0, success: true, stdout: stdout}} =
               Session.send(Session.new(config), "first")

      assert stdout =~ "turn.completed"
      assert stdout =~ "a warning"
      assert Session.session_id(session) == @uuid
      assert Session.turn_count(session) == 1
    end

    test "exposes typed turns and sums usage over repeated sends", %{tmp_dir: dir} do
      first_lines = [
        started(@uuid),
        ~s({"type":"turn.started"}),
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"first"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":0,"output_tokens":3}})
      ]

      config = fake(dir, first_lines, nil, 0)
      assert {:ok, first, %Result{} = first_result} = Session.send(Session.new(config), "first")

      assert %Turn{status: :completed, final_message: "first", thread_id: @uuid} =
               Session.last_turn(first)

      assert first.last_turn == Turn.from_result(first_result)
      assert Session.history(first) == [first_result]

      second_lines = [
        started(@uuid),
        ~s({"type":"turn.started"}),
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"second"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":5,"cache_write_input_tokens":2,"output_tokens":4,"reasoning_output_tokens":1}})
      ]

      fake(dir, second_lines, nil, 0)
      assert {:ok, second, %Result{} = second_result} = Session.send(first, "second")

      assert Session.last_turn(second).final_message == "second"
      assert Session.last_result(second) == second_result
      assert Session.history(second) == [first_result, second_result]

      assert Session.total_usage(second) == %{
               input_tokens: 17,
               cached_input_tokens: 0,
               cache_write_input_tokens: 2,
               output_tokens: 7,
               reasoning_output_tokens: 1
             }
    end

    test "exposes a failed native outcome despite a zero process exit", %{tmp_dir: dir} do
      lines = [
        started(@uuid),
        ~s({"type":"turn.failed","error":{"message":"synthetic failure"}})
      ]

      config = fake(dir, lines, nil, 0)

      assert {:ok, session, %Result{success: true}} = Session.send(Session.new(config), "first")

      assert %Turn{status: :failed, error: %{"message" => "synthetic failure"}} =
               session.last_turn

      assert Session.total_usage(session) == nil
    end
  end

  describe "typed session server access" do
    test "preserves usage and the previous turn on exit and thread mismatch failures", %{
      tmp_dir: dir
    } do
      lines = [
        started(@uuid),
        ~s({"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":0}})
      ]

      config = fake(dir, lines, nil, 0)
      {:ok, pid} = SessionServer.start_link(config: config)
      assert {:ok, %Result{} = result} = SessionServer.send_message(pid, "first")
      turn = Turn.from_result(result)
      assert SessionServer.last_turn(pid) == turn
      assert SessionServer.total_usage(pid) == turn.usage
      assert SessionServer.last_result(pid) == result

      fake(dir, lines, "synthetic failure", 7)
      assert {:error, {:exit, 7, %Result{}}} = SessionServer.send_message(pid, "second")
      assert SessionServer.last_turn(pid) == turn
      assert SessionServer.total_usage(pid) == turn.usage
      assert SessionServer.history(pid) == [result]
      assert SessionServer.turn_count(pid) == 1

      mismatched_lines = [
        started(@other),
        ~s({"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":9}})
      ]

      fake(dir, mismatched_lines, nil, 0)

      assert {:error, {:thread_mismatch, @uuid, @other, %Result{}}} =
               SessionServer.send_message(pid, "third")

      assert SessionServer.last_turn(pid) == turn
      assert SessionServer.total_usage(pid) == turn.usage
      assert SessionServer.history(pid) == [result]
      assert SessionServer.turn_count(pid) == 1
    end

    test "repeated usage reads do not replay retained raw output", %{tmp_dir: dir} do
      lines = [
        started(@uuid),
        ~s({"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":0}})
      ]

      config = fake(dir, lines, nil, 0)
      {:ok, pid} = SessionServer.start_link(config: config)
      assert {:ok, %Result{}} = SessionServer.send_message(pid, "first")
      assert {:ok, %Result{}} = SessionServer.send_message(pid, "second")
      expected = SessionServer.total_usage(pid)
      assert expected.input_tokens == 16
      assert expected.output_tokens == 0

      # Preserve the recorded totals while redacting raw payloads. Re-parsing
      # these Results instead of reading the aggregate would return nil.
      :sys.replace_state(pid, fn session ->
        history =
          Enum.map(session.history, fn %Result{} = result -> %{result | stdout: "redacted"} end)

        %{session | history: history}
      end)

      for _ <- 1..3, do: assert(SessionServer.total_usage(pid) == expected)
      assert Enum.all?(SessionServer.history(pid), &(&1.stdout == "redacted"))
    end
  end

  describe "thread id" do
    test "a session resumed by UUID refuses a different reported id", %{tmp_dir: dir} do
      config = fake(dir, [started(@other)], nil, 0)
      session = Session.resume(config, @uuid)

      assert {:error, {:thread_mismatch, @uuid, @other, %Result{exit_code: 0}}} =
               Session.send(session, "next")
    end

    test "a session resumed by name adopts the reported UUID", %{tmp_dir: dir} do
      config = fake(dir, [started(@uuid)], nil, 0)

      assert {:ok, session, _} = Session.send(Session.resume(config, "my-thread"), "next")
      assert Session.session_id(session) == @uuid
    end

    test "a blank thread id is not adopted", %{tmp_dir: dir} do
      config = fake(dir, [started("")], nil, 0)

      assert {:ok, session, _} = Session.send(Session.new(config), "first")
      assert Session.session_id(session) == nil
    end

    test "a resumed turn that reports no id keeps the session id", %{tmp_dir: dir} do
      config = fake(dir, [~s({"type":"turn.completed"})], nil, 0)

      assert {:ok, session, _} = Session.send(Session.resume(config, @uuid), "next")
      assert Session.session_id(session) == @uuid
    end
  end
end
