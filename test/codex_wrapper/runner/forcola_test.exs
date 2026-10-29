defmodule CodexWrapper.Runner.ForcolaTest do
  use ExUnit.Case, async: true

  # Drives the real forcola shim; skipped when it is not resolvable.
  @moduletag :forcola

  alias CodexWrapper.Runner.Forcola

  # Whether an OS process is still alive (kill -0 succeeds).
  defp os_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  describe "one_shot_opts/2" do
    test "defaults to SIGINT with a two-second grace" do
      opts = Forcola.one_shot_opts([], 1_000)
      assert opts[:interrupt_signal] == :int
      assert opts[:interrupt_grace_ms] == 2_000
      assert opts[:timeout_ms] == 1_000
    end

    test "keeps caller interrupt options" do
      opts = Forcola.one_shot_opts([interrupt_signal: :int, interrupt_grace_ms: 250], 1_000)
      assert Keyword.get_values(opts, :interrupt_signal) == [:int]
      assert Keyword.get_values(opts, :interrupt_grace_ms) == [250]
    end
  end

  describe "run/4" do
    test "returns stdout and a zero exit on success" do
      assert {:ok, {"hi\n", 0}} = Forcola.run("echo", ["hi"], [], 5_000)
    end

    test "a non-zero exit is a result, not an error" do
      assert {:ok, {_stdout, 7}} = Forcola.run("sh", ["-c", "exit 7"], [], 5_000)
    end

    test "merges stderr into stdout when stderr_to_stdout is set" do
      assert {:ok, {out, 0}} =
               Forcola.run(
                 "sh",
                 ["-c", "echo out; echo err 1>&2"],
                 [stderr_to_stdout: true],
                 5_000
               )

      assert out =~ "out"
      assert out =~ "err"
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Forcola.run("sleep", ["10"], [], 300)
    end

    test "a missing binary returns a spawn error" do
      assert {:error, {:spawn, _reason}} =
               Forcola.run("definitely-not-a-real-binary-xyz", [], [], 5_000)
    end

    test "a timeout sends SIGINT before SIGTERM without caller interrupt options" do
      marker =
        Path.join(System.tmp_dir!(), "cxw_forcola_int_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(marker) end)

      script = """
      trap 'exit 42' TERM
      trap '/bin/sleep 0.1; printf interrupted > #{marker}; exit 0' INT
      while :; do /bin/sleep 0.01; done
      """

      assert {:error, :timeout} = Forcola.run("sh", ["-c", script], [], 300)
      assert File.read!(marker) == "interrupted"
    end

    @tag :forcola_kill
    test "kills the child's process group on timeout (closes #33)" do
      pidfile = Path.join(System.tmp_dir!(), "cxw_forcola_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pidfile) end)

      # The child records its pid, then sleeps well past the timeout.
      assert {:error, :timeout} =
               Forcola.run("sh", ["-c", "echo $$ > #{pidfile}; sleep 30"], [], 500)

      # Forcola confirms the group is dead before run/4 returns, so the
      # recorded process must already be gone -- no leaked CLI.
      pid = pidfile |> File.read!() |> String.trim()
      refute os_alive?(pid), "expected pid #{pid} to be killed on timeout, but it is alive"
    end
  end

  describe "stream_lines/4" do
    test "emits one element per line, without trailing newlines" do
      assert ["a", "b", "c"] =
               Forcola.stream_lines("printf", ["a\nb\nc\n"], [], 5_000) |> Enum.to_list()
    end

    test "does not merge stderr into the line stream" do
      lines =
        Forcola.stream_lines("sh", ["-c", "echo out; echo err 1>&2"], [], 5_000)
        |> Enum.to_list()

      assert lines == ["out"]
    end

    test "a non-zero exit ends the stream with an exit_status item" do
      # Forcola.Stream.lines/2 raises here; the Runner contract is a final
      # error item, matching Runner.Port.
      assert ["one", {:error, {:exit_status, 3}}] =
               Forcola.stream_lines("sh", ["-c", "echo one; exit 3"], [], 5_000)
               |> Enum.to_list()
    end

    test "a zero exit ends the stream with no error item" do
      assert ["one"] =
               Forcola.stream_lines("sh", ["-c", "echo one"], [], 5_000) |> Enum.to_list()
    end

    test "death by signal ends the stream with a signal item" do
      assert ["one", {:error, {:signal, _}}] =
               Forcola.stream_lines("sh", ["-c", "echo one; kill -9 $$"], [], 5_000)
               |> Enum.to_list()
    end

    test "a whole-run timeout yields a typed error" do
      script = "echo first; sleep 10; echo never"

      assert ["first", {:error, {:timeout, 500}}] =
               Forcola.stream_lines("sh", ["-c", script], [], 500) |> Enum.to_list()
    end

    test "an idle timeout yields a distinct typed error" do
      script = "echo first; sleep 10; echo never"

      assert ["first", {:error, {:idle_timeout, 300}}] =
               Forcola.stream_lines("sh", ["-c", script], [idle_timeout_ms: 300], 5_000)
               |> Enum.to_list()
    end

    test "steady output may exceed the idle bound" do
      script = "for i in 1 2 3; do echo $i; sleep 0.15; done"

      assert ["1", "2", "3"] =
               Forcola.stream_lines("sh", ["-c", script], [idle_timeout_ms: 400], 2_000)
               |> Enum.to_list()
    end

    test "a missing binary ends the stream with a spawn item rather than raising" do
      assert [{:error, {:spawn, _reason}}] =
               Forcola.stream_lines("definitely-not-a-real-binary-xyz", [], [], 5_000)
               |> Enum.to_list()
    end

    test "an early halt does not raise" do
      assert ["y", "y"] = Forcola.stream_lines("yes", [], [], 5_000) |> Enum.take(2)
    end

    @tag :forcola_kill
    test "an early halt kills the child's process group" do
      pidfile =
        Path.join(System.tmp_dir!(), "cxw_forcola_s_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(pidfile) end)

      # One line, then a sleep well past what the consumer waits for.
      script = "echo $$ > #{pidfile}; echo line; sleep 30"

      assert ["line"] = Forcola.stream_lines("sh", ["-c", script], [], 30_000) |> Enum.take(1)

      pid = pidfile |> File.read!() |> String.trim()
      refute os_alive?(pid), "expected pid #{pid} to be killed on halt, but it is alive"
    end
  end

  describe "regression: forcola closes the child's stdin (forcola >= 0.3.4)" do
    # Before forcola 0.3.4 the child's stdin stayed open, so a process that
    # reads until EOF -- like `codex exec` with no piped prompt -- blocked
    # ("Reading additional input from stdin...") until the timeout elapsed.
    # `cat` with no arguments reads stdin the same way, without needing the
    # `codex` binary. A generous timeout paired with a much tighter elapsed
    # bound proves EOF arrived promptly rather than forcola giving up at
    # the deadline.
    test "run/4: a stdin-reading command exits well before the timeout" do
      started = System.monotonic_time(:millisecond)

      assert {:ok, {_stdout, 0}} = Forcola.run("cat", [], [], 10_000)

      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "stream_lines/4: a stdin-reading command ends the stream well before the timeout" do
      started = System.monotonic_time(:millisecond)

      assert [] = Forcola.stream_lines("cat", [], [], 10_000) |> Enum.to_list()

      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end
end
