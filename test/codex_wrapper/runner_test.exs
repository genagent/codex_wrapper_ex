defmodule CodexWrapper.RunnerTest do
  # Not async: one test overrides the :runner application env.
  use ExUnit.Case, async: false

  alias CodexWrapper.Runner

  describe "impl/0" do
    test "defaults to Runner.Port" do
      assert Runner.impl() == CodexWrapper.Runner.Port
    end

    test "honors the :runner application env" do
      Application.put_env(:codex_wrapper, :runner, CodexWrapper.Runner.Forcola)
      on_exit(fn -> Application.delete_env(:codex_wrapper, :runner) end)

      assert Runner.impl() == CodexWrapper.Runner.Forcola
    end
  end

  describe "Runner.Port.run/4" do
    alias CodexWrapper.Runner.Port

    test "returns stdout and exit code on completion" do
      assert {:ok, {"hi\n", 0}} = Port.run("echo", ["hi"], [], nil)
    end

    test "surfaces a non-zero exit code" do
      assert {:ok, {_out, 5}} = Port.run("sh", ["-c", "exit 5"], [], nil)
    end

    test "merges stderr into stdout" do
      assert {:ok, {out, 0}} = Port.run("sh", ["-c", "echo out; echo err 1>&2"], [], nil)
      assert out =~ "out"
      assert out =~ "err"
    end

    test "accepts Config-style string working directory and environment" do
      leaf = "cxw-run-cd-#{System.unique_integer([:positive])}"
      directory = Path.join(System.tmp_dir!(), leaf)
      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf(directory) end)

      assert {:ok, {output, 0}} =
               Port.run(
                 "sh",
                 ["-c", "printf '%s:%s' \"$PWD\" \"$CXW_RUN_TEST\""],
                 [cd: directory, env: [{"CXW_RUN_TEST", "from-env"}]],
                 nil
               )

      assert String.ends_with?(output, "/#{leaf}:from-env")
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Port.run("sleep", ["10"], [], 200)
    end
  end

  describe "Runner.Port.stream_lines/4" do
    alias CodexWrapper.Runner.Port

    test "emits one element per line, without trailing newlines" do
      assert ["a", "b", "c"] =
               Port.stream_lines("printf", ["a\\nb\\nc\\n"], [], 5_000) |> Enum.to_list()
    end

    test "does not merge stderr into the line stream" do
      lines =
        Port.stream_lines("sh", ["-c", "echo out; echo err 1>&2"], [], 5_000) |> Enum.to_list()

      assert lines == ["out"]
    end

    test "a non-zero exit ends the stream rather than raising" do
      assert ["one"] =
               Port.stream_lines("sh", ["-c", "echo one; exit 3"], [], 5_000) |> Enum.to_list()
    end

    test "runs in :cd, which cmd_opts/1 hands over as a string" do
      # `Config.cmd_opts/1` yields `:cd` as a string; the port paths have
      # always passed Port.open/2 a charlist. Regression against handing
      # the string straight through.
      leaf = "cxw_stream_cd_#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), leaf)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert [pwd] = Port.stream_lines("pwd", [], [cd: dir], 5_000) |> Enum.to_list()
      assert Path.basename(pwd) == leaf
    end

    test "accepts Config-style string environment pairs" do
      assert ["from-env"] =
               Port.stream_lines(
                 "sh",
                 ["-c", "echo $CXW_STREAM_TEST"],
                 [env: [{"CXW_STREAM_TEST", "from-env"}]],
                 5_000
               )
               |> Enum.to_list()
    end

    test "also accepts preconverted charlist environment pairs" do
      assert ["from-env"] =
               Port.stream_lines(
                 "sh",
                 ["-c", "echo $CXW_STREAM_TEST"],
                 [env: [{~c"CXW_STREAM_TEST", ~c"from-env"}]],
                 5_000
               )
               |> Enum.to_list()
    end

    test "an early halt terminates the stream without waiting for the process" do
      # `yes` never exits on its own, so this only returns if halting the
      # stream closes the port.
      assert ["y", "y"] = Port.stream_lines("yes", [], [], 5_000) |> Enum.take(2)
    end

    test "the idle deadline is independent of the whole-run deadline" do
      # Three lines 150ms apart outlast a 400ms idle interval, but each
      # individual gap stays below that interval.
      script = "for i in 1 2 3; do echo $i; sleep 0.15; done"

      assert ["1", "2", "3"] =
               Port.stream_lines("sh", ["-c", script], [idle_timeout_ms: 400], 2_000)
               |> Enum.to_list()
    end

    test "an idle producer yields a typed idle timeout" do
      script = "echo first; sleep 10; echo never"

      assert ["first", {:error, {:idle_timeout, 300}}] =
               Port.stream_lines("sh", ["-c", script], [idle_timeout_ms: 300], 5_000)
               |> Enum.to_list()
    end

    test "steady output cannot exceed the whole-run deadline" do
      script = "while true; do echo tick || exit; sleep 0.05; done"

      assert lines =
               Port.stream_lines("sh", ["-c", script], [idle_timeout_ms: 500], 300)
               |> Enum.to_list()

      assert List.last(lines) == {:error, {:timeout, 300}}
      assert Enum.any?(lines, &(&1 == "tick"))
    end

    test "a completed command is not timed out by a slow consumer" do
      assert ["ok"] =
               Port.stream_lines("sh", ["-c", "echo ok"], [], 200)
               |> Enum.map(fn line ->
                 Process.sleep(350)
                 line
               end)
    end

    test "a completed command retains queued lines after a slow consumer" do
      assert ["one", "two"] =
               Port.stream_lines("sh", ["-c", "printf 'one\\ntwo\\n'"], [], 200)
               |> Enum.map(fn line ->
                 Process.sleep(350)
                 line
               end)
    end

    test "an early halt while draining completed output does not wait for a close handshake" do
      task =
        Task.async(fn ->
          {micros, lines} =
            :timer.tc(fn ->
              Port.stream_lines("sh", ["-c", "printf 'one\\ntwo\\nthree\\n'"], [], 200)
              |> Stream.map(fn line ->
                Process.sleep(350)
                line
              end)
              |> Enum.take(2)
            end)

          {:messages, messages} = Process.info(self(), :messages)
          {micros, lines, messages}
        end)

      {micros, lines, messages} = Task.await(task)
      assert lines == ["one", "two"]
      assert micros < 2_000_000

      refute Enum.any?(messages, fn
               {port, {:data, _}} when is_port(port) -> true
               _ -> false
             end)
    end

    test "a completed stream returns promptly, without a close handshake" do
      {micros, _lines} =
        :timer.tc(fn -> Port.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list() end)

      # The port is already gone once :exit_status arrives, so asking it to
      # close would block for the full 5s close timeout.
      assert micros < 2_000_000
    end

    test "an oversized JSONL event becomes a typed terminal error" do
      path =
        Path.join(
          System.tmp_dir!(),
          "codex-oversized-jsonl-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(path) end)

      oversized =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => String.duplicate("x", 2_100_000)}
        })

      File.write!(path, oversized <> "\n" <> ~s({"type":"turn.completed"}) <> "\n")

      {micros, events} =
        :timer.tc(fn ->
          Port.stream_lines("sh", ["-c", ~s(cat "$1"; sleep 2), "sh", path], [], 10_000)
          |> CodexWrapper.JsonLineEvent.parse_stream()
          |> Enum.to_list()
        end)

      assert [%CodexWrapper.StreamError{reason: {:line_too_long, 1_048_576}}] = events
      assert micros < 2_000_000

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {port, _} when is_port(port) -> true
               _ -> false
             end)
    end

    test "a JSONL line at the supported size still parses" do
      path =
        Path.join(System.tmp_dir!(), "codex-max-jsonl-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      event = %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => ""}}
      base_size = event |> Jason.encode!() |> byte_size()
      line = put_in(event, ["item", "text"], String.duplicate("x", 1_048_576 - base_size))
      line = Jason.encode!(line)
      assert byte_size(line) == 1_048_576
      File.write!(path, line <> "\n")

      assert [%CodexWrapper.JsonLineEvent{event_type: "item.completed", raw: ^line}] =
               Port.stream_lines("cat", [path], [], 10_000)
               |> CodexWrapper.JsonLineEvent.parse_stream()
               |> Enum.to_list()
    end

    test "a JSONL line one byte over the supported size fails" do
      path =
        Path.join(System.tmp_dir!(), "codex-over-jsonl-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      event = %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => ""}}
      base_size = event |> Jason.encode!() |> byte_size()
      line = put_in(event, ["item", "text"], String.duplicate("x", 1_048_577 - base_size))
      line = Jason.encode!(line)
      assert byte_size(line) == 1_048_577
      File.write!(path, line <> "\n")

      assert [%CodexWrapper.StreamError{reason: {:line_too_long, 1_048_576}}] =
               Port.stream_lines("cat", [path], [], 10_000)
               |> CodexWrapper.JsonLineEvent.parse_stream()
               |> Enum.to_list()
    end

    test "an oversized line remains an error after the producer exits during slow consumption" do
      path =
        Path.join(System.tmp_dir!(), "codex-drain-jsonl-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      oversized =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => String.duplicate("x", 2_100_000)}
        })

      File.write!(path, ~s({"type":"thread.started"}) <> "\n" <> oversized <> "\n")

      assert [:started, {:error, {:line_too_long, 1_048_576}}] =
               Port.stream_lines("cat", [path], [], 200)
               |> CodexWrapper.JsonLineEvent.parse_stream()
               |> Enum.map(fn
                 %CodexWrapper.JsonLineEvent{event_type: "thread.started"} ->
                   Process.sleep(350)
                   :started

                 %CodexWrapper.StreamError{reason: reason} ->
                   {:error, reason}

                 %CodexWrapper.JsonLineEvent{event_type: type} ->
                   {:unexpected, type}
               end)

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {port, _} when is_port(port) -> true
               _ -> false
             end)
    end

    test "an unterminated oversized line does not leave a trailing Port fragment" do
      path =
        Path.join(System.tmp_dir!(), "codex-tail-jsonl-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      oversized =
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => String.duplicate("x", 1_048_600)}
        })

      File.write!(path, oversized)

      assert [%CodexWrapper.StreamError{reason: {:line_too_long, 1_048_576}}] =
               Port.stream_lines("cat", [path], [], 10_000)
               |> CodexWrapper.JsonLineEvent.parse_stream()
               |> Enum.to_list()

      receive do
        {port, message} when is_port(port) ->
          flunk("Port left a stale message: #{inspect(message)}")
      after
        20 -> :ok
      end
    end
  end

  describe "stream_lines/4 dispatch" do
    test "routes to the configured runner" do
      Application.put_env(:codex_wrapper, :runner, CodexWrapper.RunnerTest.RecordingRunner)
      on_exit(fn -> Application.delete_env(:codex_wrapper, :runner) end)

      assert ["recorded: echo hi"] =
               Runner.stream_lines("echo", ["hi"], [], nil) |> Enum.to_list()
    end

    test "falls back to Runner.Port when the runner has no stream_lines/4" do
      Application.put_env(:codex_wrapper, :runner, CodexWrapper.RunnerTest.OneShotOnlyRunner)
      on_exit(fn -> Application.delete_env(:codex_wrapper, :runner) end)

      assert ["hi"] = Runner.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list()
    end
  end

  defmodule RecordingRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}

    @impl true
    def stream_lines(binary, args, _opts, _timeout),
      do: ["recorded: #{Enum.join([binary | args], " ")}"]
  end

  defmodule OneShotOnlyRunner do
    @moduledoc false
    @behaviour CodexWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
  end
end
