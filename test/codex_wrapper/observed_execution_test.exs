defmodule CodexWrapper.ObservedExecutionTest do
  use ExUnit.Case, async: false

  @moduletag :forcola
  alias CodexWrapper.{
    Command,
    Config,
    Exec,
    ExecFork,
    ExecResume,
    Result,
    Runner,
    SessionObservation
  }

  defmodule ScriptedRunner do
    @behaviour CodexWrapper.Runner
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"legacy", 0}}

    def run_observed(_binary, _args, _opts, _timeout, {caller, reference}) do
      {test_pid, mode} = Application.fetch_env!(:codex_wrapper, :observed_test_runner)
      send(test_pid, {:helper, self(), reference})
      send(caller, {reference, {:stdout, ~s({"type":"thread.started","thread_id":"scripted"}\n)}})
      reply(mode)
    end

    defp reply(:raise), do: raise("transport failure")
    defp reply(:throw), do: throw(:transport_failure)
    defp reply(:exit), do: exit(:transport_failure)
    defp reply(:ok), do: {:ok, {"exact", 0, "diagnostic"}}
  end

  setup do
    previous = Application.get_env(:codex_wrapper, :runner)
    Application.put_env(:codex_wrapper, :runner, Runner.Forcola)

    directory =
      Path.join(System.tmp_dir!(), "codex_observed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_wrapper, :runner, previous),
        else: Application.delete_env(:codex_wrapper, :runner)

      Application.delete_env(:codex_wrapper, :observed_test_runner)
      File.rm_rf!(directory)
    end)

    %{directory: directory, reference: make_ref()}
  end

  test "fresh, resume and fork announce identity while the run is still blocked", context do
    for {module, command} <- commands() do
      release = Path.join(context.directory, "#{module}-release")

      script =
        emit(started()) <>
          ~s(while [ ! -f "$RELEASE" ]; do sleep 0.01; done\n) <>
          emit(completed())

      config = fixture(context, script, env: [{"RELEASE", release}])
      observer = {self(), context.reference}
      task = Task.async(fn -> module.execute(command, config, session_observer: observer) end)
      on_exit(fn -> Process.exit(task.pid, :kill) end)
      reference = context.reference

      assert_receive {^reference,
                      %SessionObservation{session_id: "native-thread", source: :thread_started}},
                     1_000

      assert Task.yield(task, 0) == nil
      File.write!(release, "go")
      assert {:ok, %Result{success: true}} = Task.await(task)
    end
  end

  test "exact raw stdout and stderr survive fragmented init, binary bytes and missing final newline",
       context do
    stdout = Jason.encode!(started()) <> "\n\n" <> <<255, 0>> <> "tail"
    stderr = "diagnostic\r\n" <> <<254, 0>> <> "tail"
    {first, rest} = :erlang.split_binary(stdout, 19)
    first_path = write_bytes(context, "first", first)
    rest_path = write_bytes(context, "rest", rest)
    err_path = write_bytes(context, "stderr", stderr)
    script = ~s(cat "$FIRST"\nsleep 0.02\ncat "$REST"\ncat "$ERR" >&2\n)

    assert {:ok, %Result{stdout: ^stdout, stderr: ^stderr, exit_code: 0, success: true}} =
             execute(context, script,
               env: [{"FIRST", first_path}, {"REST", rest_path}, {"ERR", err_path}]
             )

    assert_observation(context)
  end

  test "ignores malformed, wrong-envelope, blank, duplicate and conflicting init", context do
    invalid = [
      started(nil),
      started(12),
      started(""),
      started(" \n\t"),
      %{"type" => "item.completed", "thread_id" => "wrong"},
      %{"type" => "thread.started", "session_id" => "wrong"},
      ["not a map"]
    ]

    script =
      "printf 'bad json\\n'\n" <>
        Enum.map_join(invalid, &emit/1) <>
        emit(started()) <> emit(started()) <> emit(started("conflicting"))

    assert {:ok, %Result{}} = execute(context, script)
    assert_observation(context)
    reference = context.reference
    refute_receive {^reference, _}, 20
  end

  test "stderr cannot announce identity or provide the fork's ID", context do
    script =
      emit(started(), :stderr) <> emit(%{"type" => "turn.completed", "thread_id" => "wrong"})

    config = fixture(context, script)

    assert {:error, {:missing_session_id, %Result{stderr: stderr}}} =
             ExecFork.fork(ExecFork.new("source"), config, observer(context))

    assert stderr == Jason.encode!(started()) <> "\n"
    reference = context.reference
    refute_receive {^reference, _}, 20
  end

  test "successful exit does not require init and final unterminated init is observed", context do
    assert {:ok, %Result{stdout: "no init", success: true}} =
             execute(context, "printf 'no init'\n")

    reference = context.reference
    refute_receive {^reference, _}, 20

    assert {:ok, %Result{success: true}} =
             execute(
               context,
               "printf '%s' #{Command.shell_escape(Jason.encode!(started()))}\n"
             )

    assert_observation(context)
  end

  test "oversized framing is discarded until newline without changing raw result", context do
    huge = String.duplicate("x", SessionObservation.max_line_bytes() + 1)
    stdout = huge <> "\n" <> Jason.encode!(started()) <> "\n"
    path = write_bytes(context, "oversized", stdout)

    assert {:ok, %Result{stdout: ^stdout}} =
             execute(context, ~s(cat "$OUTPUT"\n), env: [{"OUTPUT", path}])

    assert_observation(context)
  end

  test "nonzero exit retains exact streams and false process success", context do
    assert {:ok, %Result{stdout: stdout, stderr: "failure", exit_code: 7, success: false}} =
             execute(context, emit(started()) <> "printf 'failure' >&2\nexit 7\n")

    assert stdout == Jason.encode!(started()) <> "\n"
    assert_observation(context)
  end

  test "signal after completed JSON is still a transport error", context do
    assert {:error, {:signal, _}} =
             execute(
               context,
               emit(started()) <> emit(completed()) <> "kill -TERM $$\n"
             )

    assert_observation(context)
  end

  test "spawn failures retain the existing Forcola error", context do
    config = Config.new(binary: Path.join(context.directory, "missing"), timeout: 500)
    assert {:error, {:spawn, _}} = Exec.execute(Exec.new("p"), config, observer(context))
  end

  test "whole-run deadline survives steady output and completed JSON is not completion",
       context do
    script =
      emit(started()) <>
        emit(completed()) <>
        "while :; do printf 'working\\n'; sleep 0.02; done\n"

    start = System.monotonic_time(:millisecond)
    assert {:error, {:timeout, 150}} = execute(context, script, timeout: 150)
    assert System.monotonic_time(:millisecond) - start < 2_000
    assert_observation(context)
  end

  test "dead observer is harmless and invalid observer fails before spawning", context do
    {pid, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    config = fixture(context, emit(started()))

    assert {:ok, %Result{}} =
             Exec.execute(Exec.new("p"), config, session_observer: {pid, context.reference})

    for invalid <- [:invalid, self(), {self(), :not_reference}, {"not a pid", make_ref()}] do
      missing = Config.new(binary: Path.join(context.directory, "missing"))

      assert {:error, :invalid_session_observer} =
               Exec.execute(Exec.new("p"), missing, session_observer: invalid)
    end
  end

  test "unsupported runner never silently falls back", context do
    Application.put_env(:codex_wrapper, :runner, Runner.Port)
    config = Config.new(binary: Path.join(context.directory, "missing"))

    for {module, command} <- commands() do
      assert {:error, {:observation_unsupported, Runner.Port}} =
               module.execute(command, config, observer(context))
    end
  end

  test "caller notification is ordered before its terminal reply", context do
    caller = self()
    reference = context.reference
    config = fixture(context, emit(started()))

    spawn(fn ->
      result = Exec.execute(Exec.new("p"), config, session_observer: {caller, reference})
      send(caller, {reference, {:returned, result}})
    end)

    assert_receive {^reference, first}, 1_000
    assert %SessionObservation{} = first
    assert_receive {^reference, {:returned, {:ok, %Result{}}}}, 1_000
  end

  test "owned helper and private messages are gone on return or exception", context do
    Application.put_env(:codex_wrapper, :runner, ScriptedRunner)
    config = Config.new(binary: "never executed")

    for mode <- [:ok, :raise, :throw, :exit] do
      Application.put_env(:codex_wrapper, :observed_test_runner, {self(), mode})
      invoke_mode(mode, config, context)
      assert_receive {:helper, helper, private_reference}
      refute Process.alive?(helper)
      refute_receive {^private_reference, _message}, 20
      assert_observation(context, "scripted")
      assert {:messages, []} = Process.info(self(), :messages)
    end
  end

  test "owner death kills owned helper, child and descendant", context do
    pidfile = Path.join(context.directory, "pids")
    script = ~s(sleep 30 &\nprintf '%s %s' "$$" "$!" > "$PIDS"\n) <> emit(started()) <> "wait\n"
    config = fixture(context, script, env: [{"PIDS", pidfile}])
    observer = observer(context)
    {owner, monitor} = spawn_monitor(fn -> Exec.execute(Exec.new("p"), config, observer) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_observation(context)
    {:links, [helper]} = Process.info(owner, :links)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    await(fn -> not Process.alive?(helper) end)
    assert_dead_pids(pidfile)
  end

  test "timeout kills child and descendant and leaves no private messages", context do
    pidfile = Path.join(context.directory, "pids")
    script = ~s(sleep 30 &\nprintf '%s %s' "$$" "$!" > "$PIDS"\n) <> emit(started()) <> "wait\n"

    assert {:error, {:timeout, 200}} =
             execute(context, script, timeout: 200, env: [{"PIDS", pidfile}])

    assert_observation(context)
    assert_dead_pids(pidfile)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "fork keeps success, nonzero, missing ID, invalid source and unsupported contracts",
       context do
    command = ExecFork.new("source")
    config = fixture(context, emit(started()) <> emit(started("later")))

    assert {:ok,
            %{
              session_id: "native-thread",
              source_session_id: "source",
              result: %Result{success: true}
            }} =
             ExecFork.fork(command, config, observer(context))

    assert_observation(context)
    config = fixture(context, "printf 'failed' >&2\nexit 3\n")

    assert {:error, {:exit, 3, %Result{stderr: "failed", success: false}}} =
             ExecFork.fork(command, config, observer(context))

    config = fixture(context, "printf \"unrecognized subcommand 'fork'\" >&2\nexit 2\n")

    assert {:error, {:unsupported, :exec_fork}} =
             ExecFork.fork(command, config, observer(context))

    assert {:error, {:invalid_session_id, ""}} =
             ExecFork.fork(ExecFork.new(""), config, observer(context))
  end

  test "legacy and empty execution options keep merged output without forcing JSON", context do
    config = fixture(context, "printf 'out'; sleep 0.02; printf 'err' >&2\n")

    for {module, command} <- commands() do
      assert {:ok, %Result{stdout: "outerr", stderr: ""}} = module.execute(command, config)
      assert {:ok, %Result{stdout: "outerr", stderr: ""}} = module.execute(command, config, [])
    end
  end

  test "exec and exec_json convenience route runtime options without losing config or CLI args",
       context do
    argsfile = Path.join(context.directory, "args")
    script = ~s(printf '%s\\n' "$@" > "$ARGS"\n) <> emit(started()) <> emit(completed())
    config = fixture(context, script)

    opts =
      [
        binary: config.binary,
        env: [{"ARGS", argsfile}],
        working_dir: context.directory,
        timeout: 1_000,
        model: "codex-model",
        output_schema: "schema.json",
        approval_policy: :never
      ] ++ observer(context)

    assert {:ok, %Result{}} = CodexWrapper.exec("-prompt", opts)
    assert_observation(context)
    argv = File.read!(argsfile)
    assert argv =~ "--json"
    assert argv =~ "--model\ncodex-model\n"
    assert argv =~ "--output-schema\nschema.json\n"
    assert argv =~ ~s(approval_policy="never")
    assert argv =~ "--\n-prompt\n"
    refute argv =~ "session_observer"
    assert {:ok, [_started, _completed]} = CodexWrapper.exec_json("p", opts)
    assert_observation(context)
    assert {:ok, %Result{}} = CodexWrapper.exec("p", Keyword.delete(opts, :session_observer))
    refute File.read!(argsfile) =~ "--json"
  end

  defp invoke_mode(:ok, config, context),
    do:
      assert(
        {:ok, %Result{stdout: "exact", stderr: "diagnostic"}} =
          Exec.execute(Exec.new("p"), config, observer(context))
      )

  defp invoke_mode(:raise, config, context),
    do:
      assert_raise(RuntimeError, "transport failure", fn ->
        Exec.execute(Exec.new("p"), config, observer(context))
      end)

  defp invoke_mode(:throw, config, context),
    do:
      assert(
        catch_throw(Exec.execute(Exec.new("p"), config, observer(context))) == :transport_failure
      )

  defp invoke_mode(:exit, config, context),
    do:
      assert(
        catch_exit(Exec.execute(Exec.new("p"), config, observer(context))) == :transport_failure
      )

  defp commands,
    do: [
      {Exec, Exec.new("p")},
      {ExecResume, ExecResume.new() |> ExecResume.session_id("source")},
      {ExecFork, ExecFork.new("source")}
    ]

  defp observer(context), do: [session_observer: {self(), context.reference}]

  defp execute(context, script, opts \\ []),
    do: Exec.execute(Exec.new("p"), fixture(context, script, opts), observer(context))

  defp fixture(context, script, opts \\ []) do
    binary = Path.join(context.directory, "fake-codex-#{System.unique_integer([:positive])}")
    File.write!(binary, "#!/bin/sh\n" <> script)
    File.chmod!(binary, 0o755)
    Config.new(Keyword.merge([binary: binary, timeout: 3_000], opts))
  end

  defp write_bytes(context, name, bytes) do
    path = Path.join(context.directory, name)
    File.write!(path, bytes)
    path
  end

  defp started(id \\ "native-thread"), do: %{"type" => "thread.started", "thread_id" => id}
  defp completed, do: %{"type" => "turn.completed", "usage" => %{}}

  defp emit(data, stream \\ :stdout) do
    redirect = if stream == :stderr, do: " >&2", else: ""
    "printf '%s\\n' #{Command.shell_escape(Jason.encode!(data))}#{redirect}\n"
  end

  defp assert_observation(context, id \\ "native-thread") do
    reference = context.reference

    assert_receive {^reference, %SessionObservation{session_id: ^id, source: :thread_started}},
                   1_000
  end

  defp assert_dead_pids(path) do
    pids = path |> File.read!() |> String.split()
    assert length(pids) == 2

    Enum.each(pids, fn pid ->
      await(fn -> elem(System.cmd("kill", ["-0", pid], stderr_to_stdout: true), 1) != 0 end)
    end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 2_000)

  defp await(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await(fun, deadline)
    end
  end
end
