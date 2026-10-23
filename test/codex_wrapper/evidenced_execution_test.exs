defmodule CodexWrapper.EvidencedExecutionTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.{
    Config,
    Exec,
    ExecFork,
    ExecResume,
    ExecutionObservation,
    Result,
    SessionObservation
  }

  defmodule Fake do
    @behaviour CodexWrapper.Runner
    def validate_options(opts) do
      CodexWrapper.Config.validate_runner_options!(opts)
      :ok
    end

    def run(binary, args, opts, timeout) do
      report(opts, {:invoked, binary, args, opts, timeout})
      {:ok, {"legacy", 0}}
    end

    def run_evidenced(binary, args, opts, timeout, {collector, ref}) do
      report(opts, {:invoked, self(), collector, ref, binary, args, opts, timeout})
      first = ~s({"type":"thread.started","thread_id":"native-thread"}\n)
      final = ~s({"type":"turn.completed","usage":{}}\n)
      <<prefix::binary-size(17), rest::binary>> = first
      send(collector, {ref, {:stdout, prefix}})
      send(collector, {ref, {:stdout, rest <> first}})
      send(collector, {ref, {:stderr, "diagnostic"}})
      send(collector, {ref, {:stdout, final}})
      stdout = first <> first <> final

      scenario(binary, stdout, timeout, collector, ref)
    end

    defp scenario("wait", stdout, _timeout, _collector, _ref) do
      receive do
        :release -> :ok
      end

      response(stdout, 0)
    end

    defp scenario("timeout", stdout, timeout, _collector, _ref) do
      {{:error, {:timeout, timeout}},
       %{
         stdout: stdout,
         stderr: "diagnostic",
         child_status: 0,
         termination: {:transport, 9},
         reason: :timeout,
         cleanup: :unconfirmed,
         scope: :process_group,
         guard_close: {:error, :guard_close_timeout}
       }}
    end

    defp scenario("signal", stdout, _timeout, _collector, _ref) do
      {{:error, {:signal, 15}},
       %{
         stdout: stdout,
         stderr: "diagnostic",
         child_signal: 15,
         termination: :exit,
         reason: nil,
         cleanup: :confirmed,
         scope: :process_group,
         guard_close: :ok
       }}
    end

    defp scenario("nonzero", stdout, _timeout, _collector, _ref) do
      response(stdout, 7)
    end

    defp scenario("worker-death", _stdout, _timeout, _collector, _ref) do
      Process.exit(self(), :kill)
    end

    defp scenario("raise", _stdout, _timeout, _collector, _ref) do
      raise "runner failed"
    end

    defp scenario("collector-death", _stdout, _timeout, collector, _ref) do
      # Give the caller time to consume identity, proving partial forwarding
      # preceded collector death; no native subprocess is involved.
      receive do
        :release -> Process.exit(collector, :kill)
      end

      receive do
        :never -> :ok
      end
    end

    defp scenario("oversize", _stdout, _timeout, collector, ref) do
      send(collector, {ref, {:stdout, String.duplicate("x", 100_000)}})
      {{:error, :max_output_bytes}, %{reason: :max_output_bytes}}
    end

    defp scenario("late", stdout, _timeout, collector, ref) do
      spawn(fn ->
        receive do
        after
          10 -> send(collector, {ref, {:stdout, "late"}})
        end
      end)

      response(stdout, 0)
    end

    defp scenario(_, stdout, _timeout, _collector, _ref) do
      response(stdout, 0)
    end

    defp response(stdout, code),
      do:
        {{:ok, {stdout, code, "diagnostic"}},
         %{
           stdout: stdout,
           stderr: "diagnostic",
           child_status: code,
           termination: :exit,
           reason: nil,
           guard_close: :ok
         }}

    defp report(opts, message) do
      opts[:env]
      |> List.keyfind("TEST_PID", 0)
      |> elem(1)
      |> String.to_charlist()
      |> :erlang.list_to_pid()
      |> send(message)
    end
  end

  defmodule LegacyOnly do
    def run(_, _, _, _), do: raise("unsupported runner invoked")
    def run_observed(_, _, _, _, _), do: raise("unsupported observed runner invoked")
  end

  defmodule Rejected do
    def run(_, _, _, _), do: raise("unsupported runner invoked")
    def run_evidenced(_, _, _, _, _), do: raise("unsupported evidenced runner invoked")
    def validate_evidence, do: {:error, :contract_unavailable}
  end

  test "nil config timeout reaches evidenced runner as a finite computed wall" do
    for {options, expected} <- [{[], 300_000}, {[timeout_ms: 700], 700}] do
      config = %{config("ok", options) | timeout: nil}
      ref = make_ref()

      assert {:ok, %Result{}} =
               Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

      assert_receive {:invoked, _, _, _, "ok", _, _, ^expected}
      assert_receive {^ref, %ExecutionObservation{}}
    end
  end

  test "fragmented native identity precedes exactly one terminal fact and final reply" do
    caller = self()
    ref = make_ref()
    config = config("wait")

    spawn(fn ->
      outcome =
        Exec.execute(Exec.new("p"), config,
          session_observer: {caller, ref},
          execution_observer: {caller, ref}
        )

      send(caller, {ref, {:reply, outcome}})
    end)

    assert_receive {:invoked, worker, collector, private_ref, "wait", args, _, _}
    assert "--json" in args
    assert_receive {^ref, %SessionObservation{session_id: "native-thread"}}
    refute_receive {^ref, %ExecutionObservation{}}, 10
    send(worker, :release)

    assert_receive {^ref,
                    %ExecutionObservation{child_status: 0, cleanup: :unknown, scope: :unknown}},
                   1_000

    assert_receive {^ref, {:reply, {:ok, %Result{success: true}}}}
    refute Process.alive?(collector)
    refute Process.alive?(worker)
    refute_receive {^private_ref, _}, 20
    refute_receive {^ref, _}, 20
  end

  test "early result and exit zero do not override timeout, cleanup or transport evidence" do
    ref = make_ref()
    assert {:error, {:timeout, 80}} = execute("timeout", ref)
    assert_receive {:invoked, _, _, _, _, _, _, _}
    assert_receive {^ref, %SessionObservation{}}

    assert_receive {^ref,
                    %ExecutionObservation{
                      child_status: 0,
                      child_signal: nil,
                      reason: :timeout,
                      termination: {:transport, 9},
                      cleanup: :unconfirmed,
                      scope: :process_group,
                      guard_close: {:error, :guard_close_timeout},
                      parsed_result: %{"type" => "turn.completed"},
                      stderr: "diagnostic",
                      stdout: stdout
                    }}

    assert stdout =~ "thread.started"
    refute_receive {^ref, _}, 20
  end

  test "nonzero and signal remain independent of parsed completion" do
    for mode <- ["nonzero", "signal"] do
      ref = make_ref()
      outcome = execute(mode, ref)
      assert_receive {:invoked, _, _, _, _, _, _, _}
      assert_receive {^ref, %SessionObservation{}}

      assert_receive {^ref,
                      %ExecutionObservation{parsed_result: %{"type" => "turn.completed"}} = fact}

      if mode == "nonzero" do
        assert {:ok, %Result{success: false, exit_code: 7}} = outcome
        assert fact.child_status == 7
        assert fact.child_signal == nil
        assert fact.cleanup == :unknown
      else
        assert outcome == {:error, {:signal, 15}}
        assert fact.child_status == nil
        assert fact.child_signal == 15
        assert fact.cleanup == :confirmed
      end

      refute_receive {^ref, _}, 10
    end
  end

  test "partial combined output stays bounded on limit and worker death" do
    for mode <- ["oversize", "worker-death"] do
      ref = make_ref()
      result = execute(mode, ref, max_output_bytes: 200)
      assert {:error, _} = result
      assert_receive {:invoked, worker, collector, private_ref, _, _, _, _}
      assert_receive {^ref, %SessionObservation{}}
      assert_receive {^ref, %ExecutionObservation{} = fact}
      assert byte_size(fact.stdout) + byte_size(fact.stderr) <= 200
      assert fact.stdout =~ "thread.started"
      assert fact.child_status == nil
      assert fact.cleanup == :unknown
      if mode == "oversize", do: assert(fact.output_truncated == true)
      refute Process.alive?(worker)
      refute Process.alive?(collector)
      refute_receive {^private_ref, _}, 20
      refute_receive {^ref, _}, 20
    end
  end

  test "collector death retains previously forwarded bounded partial output" do
    caller = self()
    ref = make_ref()
    config = config("collector-death")

    task =
      Task.async(fn ->
        Exec.execute(Exec.new("p"), config,
          session_observer: {caller, ref},
          execution_observer: {caller, ref}
        )
      end)

    assert_receive {:invoked, worker, collector, private_ref, _, _, _, _}
    assert_receive {^ref, %SessionObservation{}}
    send(worker, :release)
    assert {:error, {:io, {:observer_exit, :killed}}} = Task.await(task)
    assert_receive {^ref, %ExecutionObservation{stdout: stdout, cleanup: :unknown}}
    assert stdout =~ "thread.started"
    refute Process.alive?(collector)
    refute_receive {^private_ref, _}, 20
  end

  test "late private chunks go to a dead helper; raises still emit one terminal fact" do
    for mode <- ["late", "raise"] do
      ref = make_ref()

      if mode == "raise",
        do: assert_raise(RuntimeError, "runner failed", fn -> execute(mode, ref) end),
        else: assert({:ok, %Result{}} = execute(mode, ref))

      assert_receive {:invoked, _, collector, private_ref, _, _, _, _}
      assert_receive {^ref, %SessionObservation{}}
      assert_receive {^ref, %ExecutionObservation{}}
      refute Process.alive?(collector)
      refute_receive {^private_ref, _}, 30
      refute_receive {^ref, _}, 20
      assert {:messages, []} = Process.info(self(), :messages)
    end
  end

  test "unsupported runners and invalid session targets fail before callback invocation" do
    for {runner, expected} <- [
          {LegacyOnly, {:evidence_unsupported, LegacyOnly}},
          {Rejected, :contract_unavailable}
        ] do
      ref = make_ref()
      config = Config.new(binary: "never", runner: runner, runner_options: [])

      assert {:error, ^expected} =
               Exec.execute(Exec.new("p"), config, execution_observer: {self(), ref})

      assert_receive {^ref,
                      %ExecutionObservation{
                        termination: :pre_spawn,
                        child_status: nil,
                        child_signal: nil
                      }}

      refute_receive {^ref, _}, 10
    end

    ref = make_ref()

    assert {:error, :invalid_session_observer} =
             Exec.execute(Exec.new("p"), config("never"),
               session_observer: :invalid,
               execution_observer: {self(), ref}
             )

    assert_receive {^ref, %ExecutionObservation{termination: :pre_spawn}}
    refute_receive {:invoked, _, _, _, _, _, _, _}, 10

    assert {:error, :invalid_execution_observer} =
             Exec.execute(Exec.new("p"), config("never"), execution_observer: :invalid)
  end

  test "invalid fork source emits a pre-spawn fact without a fabricated native exit" do
    ref = make_ref()

    assert {:error, {:invalid_session_id, ""}} =
             ExecFork.execute(ExecFork.new(""), config("never"),
               execution_observer: {self(), ref}
             )

    assert_receive {^ref,
                    %ExecutionObservation{
                      termination: :pre_spawn,
                      child_status: nil,
                      child_signal: nil,
                      cleanup: :unknown
                    }}

    refute_receive {:invoked, _, _, _, _, _, _, _}, 10
    refute_receive {^ref, _}, 10
  end

  test "fresh/resume/fork and convenience JSON paths carry evidenced options" do
    for {mod, command} <- [
          {Exec, Exec.new("p")},
          {ExecResume, ExecResume.new() |> ExecResume.session_id("source")},
          {ExecFork, ExecFork.new("source")}
        ] do
      ref = make_ref()

      assert {:ok, %Result{}} =
               mod.execute(command, config("ok"), execution_observer: {self(), ref})

      assert_receive {:invoked, _, _, _, _, _, _, _}
      assert_receive {^ref, %ExecutionObservation{}}
    end

    ref = make_ref()

    assert {:ok, events} =
             CodexWrapper.exec_json("p",
               binary: "ok",
               runner: Fake,
               runner_options: [],
               env: env(),
               model: "model-a",
               execution_observer: {self(), ref}
             )

    assert length(events) == 3
    assert_receive {:invoked, _, _, _, _, args, _, _}
    assert "model-a" in args
    assert_receive {^ref, %ExecutionObservation{}}
  end

  test "owner death stops collector and worker" do
    caller = self()
    config = config("wait")

    {owner, monitor} =
      spawn_monitor(fn ->
        Exec.execute(Exec.new("p"), config, execution_observer: {caller, make_ref()})
      end)

    assert_receive {:invoked, worker, collector, _, _, _, _, _}
    collector_ref = Process.monitor(collector)
    worker_ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^collector_ref, :process, ^collector, _}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
  end

  defp execute(mode, ref, runner_options \\ []) do
    Exec.execute(Exec.new("p"), config(mode, runner_options),
      session_observer: {self(), ref},
      execution_observer: {self(), ref}
    )
  end

  defp config(mode, options \\ []),
    do: Config.new(binary: mode, runner: Fake, runner_options: options, env: env(), timeout: 80)

  defp env, do: [{"TEST_PID", self() |> :erlang.pid_to_list() |> List.to_string()}]
end
