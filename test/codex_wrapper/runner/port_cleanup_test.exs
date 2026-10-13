defmodule CodexWrapper.Runner.PortCleanupTest do
  # Not async: these tests inspect OS processes and depend on wall-clock
  # escalation, so they should not compete with each other for scheduling.
  use ExUnit.Case, async: false

  alias CodexWrapper.Command
  alias CodexWrapper.Runner.Port, as: PortRunner

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  # Trigger deadline for the timeout tests. The probe is ready within a few
  # tens of milliseconds; this leaves room for a loaded machine.
  @trigger_ms 2_500

  @probe Path.expand("../../fixtures/cleanup_probe.pl", __DIR__)
  @perl System.find_executable("perl")
  @elixir System.find_executable("elixir")

  if @perl == nil do
    @moduletag skip: "perl is required for the cleanup probe"
  end

  describe "shell_cmd_args/3" do
    test "passes the executable and arguments as positional parameters" do
      args = ["a b", "", "$(touch x)", "*"]

      assert ["-c", script, "codex-wrapper", "my codex; id" | ^args] =
               Command.shell_cmd_args("my codex; id", args)

      refute script =~ "my codex"
      refute script =~ "touch"
      assert script =~ ~s("$@" </dev/null 3<&- &)
      refute script =~ ~s("$@" </dev/null 3<&- 2>&1 &)
    end

    test "capture_stderr merges stderr into the target only" do
      assert ["-c", script | _] = Command.shell_cmd_args("codex", [], capture_stderr: true)
      assert script =~ ~s("$@" </dev/null 3<&- 2>&1 &)
    end
  end

  describe "stdin and status" do
    test "the target reads EOF from /dev/null, not the lifeline pipe" do
      assert {:ok, {"", 0}} = PortRunner.run("cat", [], [], 3_000)
    end

    test "missing, non-executable, signalled and high exit statuses are preserved", %{
      tmp_dir: dir
    } do
      missing = Path.join(dir, "missing")
      assert {:ok, {output, 127}} = PortRunner.run(missing, [], [], 5_000)
      assert output =~ missing

      plain = Path.join(dir, "plain")
      File.write!(plain, "#!/bin/sh\n")
      File.chmod!(plain, 0o644)
      assert {:ok, {_output, 126}} = PortRunner.run(plain, [], [], 5_000)

      # A target killed by a signal must not add shell job-control text to
      # the application's output.
      assert {:ok, {"before\n", 137}} =
               PortRunner.run("sh", ["-c", "echo before; kill -KILL $$"], [], 5_000)

      assert {:ok, {"", 200}} = PortRunner.run("sh", ["-c", "exit 200"], [], 5_000)
    end

    test "many short runs keep their output and status" do
      for i <- 1..30 do
        assert {:ok, {"", 7}} = PortRunner.run("sh", ["-c", "exit 7"], [], 5_000), "run #{i}"
        assert {:ok, {"hi\n", 0}} = PortRunner.run("echo", ["hi"], [], 5_000), "run #{i}"
      end
    end

    test "repeated early halts return the consumed line" do
      for i <- 1..10 do
        assert ["x"] =
                 PortRunner.stream_lines("sh", ["-c", "echo x; exec sleep 3"], [], 5_000)
                 |> Enum.take(1),
               "halt #{i}"
      end
    end
  end

  describe "normal exit" do
    test "cancels and reaps the watchdog without waiting for the cleanup schedule" do
      script = ~S"""
      echo "$PPID"
      echo "$$"
      ps -A -o pid= -o ppid=
      """

      {micros, result} = :timer.tc(fn -> PortRunner.run("sh", ["-c", script], [], 5_000) end)
      assert {:ok, {output, 0}} = result
      assert micros < 2_000_000

      [supervisor, target | process_table] = String.split(output, "\n", trim: true)
      supervisor = String.to_integer(supervisor)
      target = String.to_integer(target)
      watchdogs = children_in(process_table, supervisor) -- [target]

      # The target ran while the supervisor and its watchdog were alive.
      assert [_watchdog] = watchdogs
      assert_all_gone([supervisor | watchdogs], 1_000)
    end
  end

  describe "run/4 timeout" do
    test "sends INT to a cooperating handler, which removes its tool in another group", %{
      tmp_dir: dir
    } do
      task =
        Task.async(fn ->
          :timer.tc(fn -> PortRunner.run(@perl, probe_args(dir, "int"), [], @trigger_ms) end)
        end)

      info = await_ready!(dir)
      {micros, result} = Task.await(task, 10_000)

      assert result == {:error, :timeout}
      # The caller is not held for any part of the cleanup schedule.
      assert micros < @trigger_ms * 1_000 + 1_000_000
      assert_cooperative_int(dir, info)
    end

    test "falls back to TERM when INT is ignored, with PATH replaced", %{tmp_dir: dir} do
      args = probe_args(dir, "ignore-int")
      opts = [env: [{"PATH", dir}]]

      task = Task.async(fn -> PortRunner.run(@perl, args, opts, @trigger_ms) end)

      info = await_ready!(dir)
      assert Task.await(task, 10_000) == {:error, :timeout}

      assert_all_gone(all_pids(info), 6_000)
      assert [{"INT", int_at}, {"TERM", term_at}] = signals(dir)
      assert_escalation_gap(int_at, term_at)
      assert File.read!(Path.join(dir, "events")) == "tool-reaped\n"
    end
  end

  describe "stream_lines/4 triggers" do
    test "whole-run timeout", %{tmp_dir: dir} do
      task =
        Task.async(fn ->
          PortRunner.stream_lines(@perl, probe_args(dir, "int"), [], @trigger_ms)
          |> Enum.to_list()
        end)

      info = await_ready!(dir)
      assert Task.await(task, 10_000) == [{:error, {:timeout, @trigger_ms}}]
      assert_cooperative_int(dir, info)
    end

    test "idle timeout", %{tmp_dir: dir} do
      task =
        Task.async(fn ->
          PortRunner.stream_lines(@perl, probe_args(dir, "int"), [idle_timeout_ms: 1_500], 30_000)
          |> Enum.to_list()
        end)

      info = await_ready!(dir)
      assert Task.await(task, 10_000) == [{:error, {:idle_timeout, 1_500}}]
      assert_cooperative_int(dir, info)
    end

    test "early halt", %{tmp_dir: dir} do
      # The probe prints its line only after publishing `ready`, and the port
      # stays open until `take/2` halts, so the watchdog can be located here.
      assert [{"ready", info}] =
               PortRunner.stream_lines(@perl, probe_args(dir, "int", "announce"), [], 30_000)
               |> Stream.map(fn line -> {line, await_ready!(dir)} end)
               |> Enum.take(1)

      assert_cooperative_int(dir, info)
    end

    test "exception in the consumer", %{tmp_dir: dir} do
      test_pid = self()

      assert_raise RuntimeError, "boom", fn ->
        PortRunner.stream_lines(@perl, probe_args(dir, "int", "announce"), [], 30_000)
        |> Enum.each(fn _line ->
          send(test_pid, {:info, await_ready!(dir)})
          raise "boom"
        end)
      end

      assert_receive {:info, info}
      assert_cooperative_int(dir, info)
    end

    test "oversized line", %{tmp_dir: dir} do
      assert [{:error, {:line_too_long, 1_048_576}}] =
               PortRunner.stream_lines(@perl, probe_args(dir, "int", "oversize"), [], 30_000)
               |> Enum.to_list()

      # The port is already closing, so the watchdog may be gone.
      info = await_ready!(dir, watchdog: false)

      # The probe is still writing when the port closes, so it may die of a
      # broken pipe before its INT handler removes the tool. Only the
      # processes the runner owns are asserted here.
      assert_all_gone([info.supervisor, info.target | info.watchdogs], 4_000)
    end

    test "a target without its own INT handler is stopped by TERM" do
      assert [pid_line] =
               PortRunner.stream_lines("sh", ["-c", "echo $$; exec sleep 30"], [], 30_000)
               |> Enum.take(1)

      pid = String.to_integer(pid_line)
      on_exit(fn -> force_kill(pid) end)
      assert_all_gone([pid], 5_000)
    end

    test "the caller is not held through KILL escalation", %{tmp_dir: dir} do
      timeout = 1_500

      task =
        Task.async(fn ->
          :timer.tc(fn ->
            PortRunner.stream_lines(@perl, probe_args(dir, "ignore-all"), [], timeout)
            |> Enum.to_list()
          end)
        end)

      info = await_ready!(dir)
      {micros, lines} = Task.await(task, 10_000)

      assert lines == [{:error, {:timeout, timeout}}]
      assert micros < timeout * 1_000 + 1_000_000

      # INT and TERM are ignored; only the final KILL ends the probe. The tool
      # is in another group, is not signalled, and is cleaned up on exit.
      assert_all_gone([info.supervisor, info.target | info.watchdogs], 8_000)
      assert [{"INT", int_at}, {"TERM", term_at}] = signals(dir)
      assert_escalation_gap(int_at, term_at)
    end
  end

  describe "port owner death" do
    test "of a synchronous run", %{tmp_dir: dir} do
      owner = spawn(fn -> PortRunner.run(@perl, probe_args(dir, "int"), [], nil) end)
      info = await_ready!(dir)
      Process.exit(owner, :kill)

      assert_cooperative_int(dir, info)
    end

    test "of a stream", %{tmp_dir: dir} do
      owner =
        spawn(fn ->
          PortRunner.stream_lines(@perl, probe_args(dir, "int"), [], nil) |> Enum.to_list()
        end)

      info = await_ready!(dir)
      Process.exit(owner, :kill)

      assert_cooperative_int(dir, info)
    end
  end

  if @elixir do
    describe "BEAM death" do
      for kind <- [:run, :stream] do
        @kind kind

        test "killing the BEAM OS process that owns a #{kind}", %{tmp_dir: dir} do
          pidfile = Path.join(dir, "beam.pid")
          _port = start_disposable_beam(@kind, dir, pidfile)

          info = await_ready!(dir, timeout: 30_000)
          beam_pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()
          on_exit(fn -> force_kill(beam_pid) end)
          assert alive?(beam_pid)

          assert {_, 0} = System.cmd("kill", ["-9", Integer.to_string(beam_pid)])
          assert_cooperative_int(dir, info)
        end
      end
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp probe_args(dir, mode, output \\ "quiet"), do: [@probe, dir, mode, output]

  defp start_disposable_beam(kind, dir, pidfile) do
    arguments = "#{inspect(@perl)}, #{inspect(probe_args(dir, "int"))}, [], nil"

    call =
      case kind do
        :run -> "CodexWrapper.Runner.Port.run(#{arguments})"
        :stream -> "CodexWrapper.Runner.Port.stream_lines(#{arguments}) |> Enum.to_list()"
      end

    code = "File.write!(#{inspect(pidfile)}, System.pid())\n" <> call
    ebin = Path.join(Mix.Project.app_path(), "ebin")

    Port.open({:spawn_executable, @elixir}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-pa", ebin, "-e", code]
    ])
  end

  # Waits for the probe to publish its pids, checks that the tool really is in
  # another process group, and finds the supervisor's watchdog while it is
  # still blocked waiting for EOF. Call it before the port is closed; pass
  # `watchdog: false` when the port may already be closing.
  defp await_ready!(dir, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout, 5_000)
    path = Path.join(dir, "ready")
    assert wait_until(fn -> File.exists?(path) end, timeout_ms), "probe never became ready"

    info =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {String.to_atom(key), String.to_integer(value)}
      end)

    on_exit(fn -> Enum.each([info.target, info.tool], &force_kill/1) end)

    assert info.tool_pgid == info.tool
    assert info.tool_pgid != info.target_pgid

    if Keyword.get(opts, :watchdog, true) do
      watchdogs = children_of(info.supervisor) -- [info.target]
      assert [_watchdog] = watchdogs
      Map.put(info, :watchdogs, watchdogs)
    else
      Map.put(info, :watchdogs, [])
    end
  end

  defp all_pids(info), do: [info.supervisor, info.target, info.tool | info.watchdogs]

  # INT reached the probe's own handler, which removed and reaped the tool in
  # the other process group; TERM was never needed.
  defp assert_cooperative_int(dir, info) do
    assert_all_gone(all_pids(info), 4_000)
    assert [{"INT", _at}] = signals(dir)
    assert File.read!(Path.join(dir, "events")) == "tool-reaped\n"
  end

  # Nominal gap is two seconds; allow for scheduler delay either way.
  defp assert_escalation_gap(int_at, term_at) do
    gap = term_at - int_at
    assert gap >= 1.5, "TERM followed INT after #{gap}s"
    assert gap < 4.0, "TERM followed INT after #{gap}s"
  end

  defp assert_all_gone(pids, timeout_ms) do
    gone? = wait_until(fn -> Enum.all?(pids, &(not alive?(&1))) end, timeout_ms)
    assert gone?, "still alive after #{timeout_ms}ms: #{inspect(Enum.filter(pids, &alive?/1))}"
  end

  defp signals(dir) do
    case File.read(Path.join(dir, "signals")) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [name, at] = String.split(line, " ")
          {name, String.to_float(at)}
        end)

      {:error, :enoent} ->
        []
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  # A zombie awaiting its parent's wait() is not running; count it as gone.
  defp alive?(pid) do
    args = ["-o", "stat=", "-p", Integer.to_string(pid)]

    case System.cmd("ps", args, stderr_to_stdout: true) do
      {output, 0} ->
        stat = String.trim(output)
        stat != "" and not String.starts_with?(stat, "Z")

      _ ->
        false
    end
  end

  defp children_of(pid) do
    {output, 0} = System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="])
    children_in(String.split(output, "\n", trim: true), pid)
  end

  # `lines` are `ps -o pid= -o ppid=` rows.
  defp children_in(lines, pid) do
    Enum.flat_map(lines, fn line ->
      [child, parent] = line |> String.split() |> Enum.map(&String.to_integer/1)
      if parent == pid, do: [child], else: []
    end)
  end

  defp force_kill(pid) do
    System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
