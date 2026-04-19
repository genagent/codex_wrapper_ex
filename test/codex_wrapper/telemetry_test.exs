defmodule CodexWrapper.TelemetryTest do
  use ExUnit.Case, async: false

  alias CodexWrapper.{Commands.Fork, Exec, ExecResume, Result, Review, Telemetry}

  describe "span/3" do
    test "emits start and stop events for a successful call" do
      handler_id = attach_handler([:codex_wrapper, :fake])

      result =
        Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
          :ok
        end)

      assert result == :ok

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.monotonic_time)
      assert start_metadata.command == :fake

      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.command == :fake

      detach_handler(handler_id)
    end

    test "adds exit_code to stop metadata when result is {:ok, %Result{}}" do
      handler_id = attach_handler([:codex_wrapper, :fake])

      Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
        {:ok, %Result{stdout: "", stderr: "", exit_code: 0, success: true}}
      end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}

      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _measurements, stop_metadata}

      assert stop_metadata.exit_code == 0

      detach_handler(handler_id)
    end

    test "adds exit_code from {:ok, result, extra} tuple" do
      handler_id = attach_handler([:codex_wrapper, :fake])

      Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
        {:ok, %Result{stdout: "", stderr: "", exit_code: 42, success: false}, []}
      end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}
      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, stop_metadata}
      assert stop_metadata.exit_code == 42

      detach_handler(handler_id)
    end

    test "omits exit_code when result is not a Result struct" do
      handler_id = attach_handler([:codex_wrapper, :fake])

      Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
        {:error, :something}
      end)

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}
      assert_receive {:telemetry, [:codex_wrapper, :fake, :stop], _, stop_metadata}
      refute Map.has_key?(stop_metadata, :exit_code)

      detach_handler(handler_id)
    end

    test "emits exception event when the function raises" do
      handler_id = attach_handler([:codex_wrapper, :fake])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:codex_wrapper, :fake], %{command: :fake}, fn ->
          raise "boom"
        end)
      end

      assert_receive {:telemetry, [:codex_wrapper, :fake, :start], _, _}

      assert_receive {:telemetry, [:codex_wrapper, :fake, :exception], _measurements,
                      exception_metadata}

      assert exception_metadata.kind == :error
      assert %RuntimeError{message: "boom"} = exception_metadata.reason
      assert is_list(exception_metadata.stacktrace)

      detach_handler(handler_id)
    end
  end

  describe "exec_metadata/2" do
    test "extracts command, session_id, sandbox, and approval_policy from Exec" do
      exec =
        Exec.new("hello")
        |> Exec.sandbox(:workspace_write)
        |> Exec.approval_policy(:on_failure)

      metadata = Telemetry.exec_metadata(:exec, exec)

      assert metadata.command == :exec
      assert metadata.sandbox_mode == :workspace_write
      assert metadata.approval_policy == :on_failure
      assert metadata.session_id == nil
    end

    test "extracts session_id from ExecResume" do
      resume =
        ExecResume.new()
        |> ExecResume.session_id("abc-123")
        |> ExecResume.prompt("continue")

      metadata = Telemetry.exec_metadata(:exec_resume, resume)

      assert metadata.command == :exec_resume
      assert metadata.session_id == "abc-123"
      assert metadata.sandbox_mode == nil
      assert metadata.approval_policy == nil
    end

    test "extracts fields from Fork" do
      fork =
        Fork.new()
        |> Fork.session_id("sess-1")
        |> Fork.sandbox(:read_only)
        |> Fork.approval_policy(:never)

      metadata = Telemetry.exec_metadata(:session_fork, fork)

      assert metadata.command == :session_fork
      assert metadata.session_id == "sess-1"
      assert metadata.sandbox_mode == :read_only
      assert metadata.approval_policy == :never
    end
  end

  describe "review_metadata/2" do
    test "returns nil for sandbox and approval policy" do
      review = Review.new() |> Review.base("main")

      metadata = Telemetry.review_metadata(:review, review)

      assert metadata.command == :review
      assert metadata.session_id == nil
      assert metadata.sandbox_mode == nil
      assert metadata.approval_policy == nil
    end
  end

  describe "session_turn_metadata/3" do
    test "prefers explicit session_id over builder's field" do
      exec = Exec.new("hello")

      metadata = Telemetry.session_turn_metadata(:session_exec, exec, "outer-sid")

      assert metadata.command == :session_exec
      assert metadata.session_id == "outer-sid"
    end

    test "falls back to builder's session_id when explicit is nil" do
      resume = ExecResume.new() |> ExecResume.session_id("inner-sid")

      metadata = Telemetry.session_turn_metadata(:session_resume, resume, nil)

      assert metadata.session_id == "inner-sid"
    end
  end

  # --- Helpers ---

  defp attach_handler(event_prefix) do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    events =
      for suffix <- [:start, :stop, :exception] do
        event_prefix ++ [suffix]
      end

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  defp detach_handler(handler_id) do
    :telemetry.detach(handler_id)
  end
end
