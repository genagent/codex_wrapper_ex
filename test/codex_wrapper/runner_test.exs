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

    test "passes :env through" do
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

    test "the timeout is an idle bound between lines, not a whole-run bound" do
      # Three lines 150ms apart is 450ms of runtime under a 400ms bound:
      # a whole-run bound would truncate it, an idle bound does not.
      script = "for i in 1 2 3; do echo $i; sleep 0.15; done"

      assert ["1", "2", "3"] =
               Port.stream_lines("sh", ["-c", script], [], 400) |> Enum.to_list()
    end

    test "an idle producer is cut off at the timeout" do
      script = "echo first; sleep 10; echo never"

      assert ["first"] = Port.stream_lines("sh", ["-c", script], [], 300) |> Enum.to_list()
    end

    test "a completed stream returns promptly, without a close handshake" do
      {micros, _lines} =
        :timer.tc(fn -> Port.stream_lines("echo", ["hi"], [], 5_000) |> Enum.to_list() end)

      # The port is already gone once :exit_status arrives, so asking it to
      # close would block for the full 5s close timeout.
      assert micros < 2_000_000
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
