defmodule CodexWrapper.TelemetryTest do
  use ExUnit.Case, async: false

  alias CodexWrapper.{Config, Exec, ExecResume, JsonLineEvent, Result, Review, Session, Telemetry}

  defmodule ScriptedRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout) do
      {test_pid, stdout} = Application.fetch_env!(:codex_wrapper, :telemetry_test_runner)
      send(test_pid, {:runner_run, binary, args, opts, timeout})
      {:ok, {stdout, 0}}
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      {test_pid, stdout} = Application.fetch_env!(:codex_wrapper, :telemetry_test_runner)
      send(test_pid, {:runner_stream, binary, args, opts, timeout})
      String.split(stdout, "\n", trim: true)
    end
  end

  @event_prefixes [
    [:codex_wrapper, :fake],
    [:codex_wrapper, :exec],
    [:codex_wrapper, :stream],
    [:codex_wrapper, :review],
    [:codex_wrapper, :session, :turn]
  ]

  @doc false
  def forward_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  setup context do
    handler_id = "codex-wrapper-telemetry-#{inspect(context.test)}"

    events =
      for prefix <- @event_prefixes,
          suffix <- [:start, :stop, :exception] do
        prefix ++ [suffix]
      end

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.forward_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "span/3" do
    test "emits start and stop while preserving the return value" do
      assert :ok =
               Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn -> :ok end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.monotonic_time)
      assert is_integer(start_measurements.system_time)
      assert start_metadata.command == :fake

      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.monotonic_time)
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.command == :fake
    end

    test "adds a Result exit code to stop metadata" do
      result = %Result{stdout: "", stderr: "", exit_code: 42, success: false}

      assert {:ok, ^result} =
               Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
                 {:ok, result}
               end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}
      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, metadata}
      assert metadata.exit_code == 42
    end

    test "adds a Result exit code from a session-style tuple" do
      result = %Result{stdout: "", stderr: "", exit_code: 0, success: true}

      assert {:ok, ^result, []} =
               Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
                 {:ok, result, []}
               end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, metadata}
      assert metadata.exit_code == 0
    end

    test "does not invent an exit code for other results" do
      assert {:error, :timeout} =
               Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
                 {:error, :timeout}
               end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, metadata}
      refute Map.has_key?(metadata, :exit_code)
    end

    test "emits exception instead of stop when the function raises" do
      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
          raise "boom"
        end)
      end

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}
      assert_receive {:telemetry, [:codex_wrapper, :fake, :exception], measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "boom"} = metadata.reason
      assert is_list(metadata.stacktrace)
      refute_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, _}
    end
  end

  describe "span_stream/3" do
    test "is lazy and measures the full consumption lifetime" do
      test_pid = self()

      stream =
        Telemetry.span_stream([:codex_wrapper, :stream], %{command: :exec}, fn ->
          send(test_pid, :producer_built)

          Stream.map([:event], fn event ->
            Process.sleep(20)
            event
          end)
        end)

      refute_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}
      refute_receive :producer_built

      assert [:event] = Enum.to_list(stream)

      assert_receive {:telemetry, [:codex_wrapper, :stream, :start], _, %{command: :exec}}
      assert_receive :producer_built
      assert_receive {:telemetry, [:codex_wrapper, :stream, :stop], measurements, metadata}

      assert System.convert_time_unit(measurements.duration, :native, :millisecond) >= 10
      refute Map.has_key?(metadata, :exit_code)
    end

    test "halts and cleans up the producer before emitting stop" do
      test_pid = self()

      stream =
        Telemetry.span_stream([:codex_wrapper, :stream], %{command: :exec}, fn ->
          Stream.resource(
            fn ->
              send(test_pid, :producer_opened)
              0
            end,
            fn value -> {[value], value + 1} end,
            fn _state -> send(test_pid, :producer_closed) end
          )
        end)

      assert [0] = Enum.take(stream, 1)

      assert_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}
      assert_receive :producer_opened
      assert_receive :producer_closed
      assert_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, _}
      refute_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, _}
    end

    test "emits exception, cleans up, and does not emit stop when the producer raises" do
      test_pid = self()

      stream =
        Telemetry.span_stream([:codex_wrapper, :stream], %{command: :review}, fn ->
          Stream.resource(
            fn ->
              send(test_pid, :producer_opened)
              :state
            end,
            fn :state -> raise "producer failed" end,
            fn :state -> send(test_pid, :producer_closed) end
          )
        end)

      assert_raise RuntimeError, "producer failed", fn -> Enum.to_list(stream) end

      assert_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}
      assert_receive :producer_opened
      assert_receive :producer_closed

      assert_receive {:telemetry, [:codex_wrapper, :stream, :exception], measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.command == :review
      assert metadata.kind == :error
      assert %RuntimeError{message: "producer failed"} = metadata.reason
      refute_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, _}
    end

    test "emits exception when stream construction raises on first consume" do
      stream =
        Telemetry.span_stream([:codex_wrapper, :stream], %{command: :exec_resume}, fn ->
          raise "cannot construct"
        end)

      refute_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}

      assert_raise RuntimeError, "cannot construct", fn -> Enum.to_list(stream) end

      assert_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}
      assert_receive {:telemetry, [:codex_wrapper, :stream, :exception], _, metadata}
      assert %RuntimeError{message: "cannot construct"} = metadata.reason
      refute_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, _}
    end

    test "emits exception when the consumer raises" do
      stream =
        Telemetry.span_stream([:codex_wrapper, :stream], %{command: :exec}, fn -> [1] end)

      assert_raise RuntimeError, "consumer failed", fn ->
        Enum.each(stream, fn _event -> raise "consumer failed" end)
      end

      assert_receive {:telemetry, [:codex_wrapper, :stream, :exception], _, metadata}
      assert %RuntimeError{message: "consumer failed"} = metadata.reason
      refute_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, _}
    end
  end

  describe "instrumented command paths" do
    setup do
      previous_runner = Application.fetch_env(:codex_wrapper, :runner)
      previous_script = Application.fetch_env(:codex_wrapper, :telemetry_test_runner)
      stdout = "{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}\n"

      Application.put_env(:codex_wrapper, :runner, ScriptedRunner)
      Application.put_env(:codex_wrapper, :telemetry_test_runner, {self(), stdout})

      on_exit(fn ->
        restore_env(:runner, previous_runner)
        restore_env(:telemetry_test_runner, previous_script)
      end)

      %{config: Config.new(binary: "codex")}
    end

    test "execute_json emits one exec span with the real command metadata", %{config: config} do
      assert {:ok, [%JsonLineEvent{event_type: "thread.started"}]} =
               "hello" |> Exec.new() |> Exec.execute_json(config)

      assert_receive {:telemetry, [:codex_wrapper, :exec, :start], _, start_metadata}
      assert start_metadata.command == :exec
      assert_receive {:runner_run, "codex", args, _opts, _timeout}
      assert "--json" in args
      assert_receive {:telemetry, [:codex_wrapper, :exec, :stop], _, stop_metadata}
      assert stop_metadata.command == :exec
      assert stop_metadata.exit_code == 0
      refute_receive {:telemetry, [:codex_wrapper, :exec, :start], _, _}
    end

    test "resume and review execute paths use their documented events", %{config: config} do
      assert {:ok, %Result{}} =
               ExecResume.new()
               |> ExecResume.session_id("thread-1")
               |> ExecResume.prompt("continue")
               |> ExecResume.execute(config)

      assert_receive {:telemetry, [:codex_wrapper, :exec, :start], _,
                      %{command: :exec_resume, session_id: "thread-1"}}

      assert_receive {:telemetry, [:codex_wrapper, :exec, :stop], _,
                      %{command: :exec_resume, exit_code: 0}}

      assert {:ok, %Result{}} = Review.new() |> Review.uncommitted() |> Review.execute(config)

      assert_receive {:telemetry, [:codex_wrapper, :review, :start], _, %{command: :review}}

      assert_receive {:telemetry, [:codex_wrapper, :review, :stop], _,
                      %{command: :review, exit_code: 0}}
    end

    test "all stream call sites stay lazy and emit their real command", %{config: config} do
      streams = [
        {:exec, Exec.stream(Exec.new("hello"), config)},
        {
          :exec_resume,
          ExecResume.new()
          |> ExecResume.session_id("thread-1")
          |> ExecResume.prompt("continue")
          |> ExecResume.stream(config)
        },
        {:review, Review.new() |> Review.uncommitted() |> Review.stream(config)}
      ]

      refute_receive {:runner_stream, _, _, _, _}
      refute_receive {:telemetry, [:codex_wrapper, :stream, :start], _, _}

      Enum.each(streams, fn {command, stream} ->
        assert [%JsonLineEvent{event_type: "thread.started"}] = Enum.to_list(stream)

        assert_receive {:telemetry, [:codex_wrapper, :stream, :start], _, %{command: ^command}}

        assert_receive {:runner_stream, "codex", _args, _opts, _timeout}

        assert_receive {:telemetry, [:codex_wrapper, :stream, :stop], _, stop_metadata}
        assert stop_metadata.command == command
        refute Map.has_key?(stop_metadata, :exit_code)
      end)
    end

    test "session send wraps the nested exec span in a session-turn span", %{config: config} do
      session = Session.new(config)

      assert {:ok, updated_session, %Result{exit_code: 0}} =
               Session.send(session, "hello")

      assert updated_session.session_id == "thread-1"

      assert_receive {:telemetry, [:codex_wrapper, :session, :turn, :start], _,
                      %{command: :session_exec}}

      assert_receive {:telemetry, [:codex_wrapper, :exec, :start], _, %{command: :exec}}
      assert_receive {:runner_run, "codex", _args, _opts, _timeout}

      assert_receive {:telemetry, [:codex_wrapper, :exec, :stop], _,
                      %{command: :exec, exit_code: 0}}

      assert_receive {:telemetry, [:codex_wrapper, :session, :turn, :stop], _,
                      %{command: :session_exec, exit_code: 0}}
    end
  end

  describe "metadata builders" do
    test "extracts fields from Exec" do
      exec =
        "hello"
        |> Exec.new()
        |> Exec.sandbox(:workspace_write)
        |> Exec.approval_policy(:on_request)

      metadata = Telemetry.exec_metadata(:exec, exec)

      assert metadata == %{
               command: :exec,
               session_id: nil,
               sandbox_mode: :workspace_write,
               approval_policy: :on_request
             }
    end

    test "extracts session and sandbox fields from ExecResume" do
      resume =
        ExecResume.new()
        |> ExecResume.session_id("abc-123")
        |> ExecResume.sandbox(:read_only)

      metadata = Telemetry.exec_metadata(:exec_resume, resume)

      assert metadata.command == :exec_resume
      assert metadata.session_id == "abc-123"
      assert metadata.sandbox_mode == :read_only
      assert metadata.approval_policy == nil
    end

    test "extracts Review sandbox metadata" do
      review = Review.new() |> Review.sandbox(:danger_full_access)

      metadata = Telemetry.review_metadata(:review, review)

      assert metadata.command == :review
      assert metadata.session_id == nil
      assert metadata.sandbox_mode == :danger_full_access
      assert metadata.approval_policy == nil
    end

    test "prefers the established session id for a session turn" do
      resume = ExecResume.new() |> ExecResume.session_id("builder-session")

      metadata =
        Telemetry.session_turn_metadata(:session_resume, resume, "established-session")

      assert metadata.command == :session_resume
      assert metadata.session_id == "established-session"
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:codex_wrapper, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:codex_wrapper, key)
end
